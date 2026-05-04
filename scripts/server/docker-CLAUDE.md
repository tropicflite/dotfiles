# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Managing Stacks

All stacks follow the same pattern. From the stack's directory:

```bash
docker compose up -d          # start
docker compose down           # stop
docker compose pull && docker compose up -d  # update
docker compose logs -f        # tail logs
docker compose logs -f <svc>  # logs for one service
```

Two stacks are managed by systemd services (so they start on boot):
- `homepage`: `homepage-compose.service` — starts after `docker.service` and `tailscaled.service`
- `pihole`: `pihole-compose.service` — starts after `wg0.service` and `docker.service`

Use `sudo systemctl start|stop|restart homepage-compose` / `pihole-compose` for those rather than bare `docker compose`.

## Architecture

### Networks

There are four named Docker networks:

| Network | Bridge | Subnet | Purpose |
|---------|--------|--------|---------|
| `arrs` | (default) | — | Shared by arrs stack, jellyfin, qbittorrent, and homepage; allows inter-container name resolution |
| `pihole_net` | `br-pihole` | `172.20.0.0/24` | Isolated bridge for Pi-hole; NAT'd through wg0 via iptables |
| `qbittorrent` | `br-qbittorrent` | `172.22.0.0/24` | Kill-switch bridge: iptables blocks all forwarding to `enp1s0`/`wlp2s0`; only wg0 is permitted |
| `uptime-kuma_default` (alias `kuma`) | — | — | Immich joins this so Uptime Kuma can probe it |

**qBittorrent kill switch:** enforced by iptables rules in `~/dotfiles/scripts/server/wg0-up-extra.sh`, which runs as `ExecStartPost` of `wg0.service`. If wg0 is down, qBittorrent has no internet access.

**Pi-hole routing through VPN:** same script also NAT-masquerades `172.20.0.0/24` through wg0.

### Volume conventions

Most config and data is bind-mounted, not in named volumes:

- Stack-local config: `./service/config` inside the stack directory (e.g. `arrs/prowlarr/config`)
- Shared media tree: `/mnt/data/media/{movies,tv}` — mounted into Radarr, Sonarr, Bazarr, Jellyfin, qBittorrent, and Filebrowser
- Torrent paths: `/mnt/data/torrents/{downloads,incomplete}` — mounted into Radarr, Sonarr, and qBittorrent
- Immich library: `/mnt/data/immich/library` (set via `UPLOAD_LOCATION` in `immich/.env`)
- Immich Postgres: `/mnt/data/immich/postgres` (set via `DB_DATA_LOCATION` in `immich/.env`)
- Jellyfin config/cache: `/opt/docker/jellyfin/{config,cache}` (not under `~/docker`)
- Filebrowser root: `/mnt/data` (entire data mount) plus `/home/matt`
- `open-webui` data: named Docker volume `open-webui` (external — must exist before `docker compose up`)
- Immich ML models: named Docker volume `immich_model-cache` (auto-created by compose, not external)
- Uptime Kuma data: `/home/matt/docker/uptime-kuma` (compose working dir, not a subdirectory)

### Service relationships

- **Prowlarr** is the indexer manager; Radarr and Sonarr pull indexers from it via the `arrs` network.
- **Radarr/Sonarr** send completed downloads to qBittorrent and import from `/mnt/data/torrents`. They are on both the `arrs` network and share the same `/mnt/data` mount tree as qBittorrent.
- **Bazarr** handles subtitles for Radarr/Sonarr content; mounts `/mnt/data/media` but not the torrents path.
- **Jellyseerr** is the request front-end; it talks to Jellyfin, Radarr, and Sonarr by container name over `arrs`.
- **FlareSolverr** provides Cloudflare bypass for Prowlarr; runs on `:8191`.
- **Jellyfin** uses `/dev/dri/renderD128` for Intel GPU hardware transcoding (group `992` = render group) and is on the `arrs` network so Jellyseerr can reach it by name.
- **Open WebUI** connects to Ollama on the desktop machine via Tailscale IP `100.78.51.10:11434` (not a local container). TTS is provided by a co-located `openai-edge-tts` sidecar.
- **Homepage** joins the `arrs` network so it can contact arrs-stack services by container name for its widgets. It also mounts the Docker socket read-only for container status.
- **Uptime Kuma** uses `host.docker.internal:host-gateway` to reach host-bound ports. Immich joins the `uptime-kuma_default` network so Kuma can probe it by container name.
- **Filebrowser** binds only to `127.0.0.1:8081` — exposed externally via Tailscale Serve/Funnel or a reverse proxy, not directly.

### Access

All services are accessed over Tailscale. The server's Tailscale hostname is `server.tailc9871d.ts.net` (IP `100.65.250.53`). Pi-hole and Homepage have `restart: unless-stopped` and are started by systemd services on boot.

**Tailscale Serve port mappings** — several services use a different external port than the container port. Do not confuse these when editing `services.yaml` or compose files; the `href` in Homepage must use the Tailscale (external) port:

| Service | Tailscale external port | Container internal port |
|---------|------------------------|------------------------|
| Jellyfin | 8097 | 8096 |
| Pi-hole | 8090 | 8091 |
| qBittorrent | 8082 | 8080 |
| Open WebUI | 443 (default HTTPS) | 8083 |
| Homepage | 3000 | 3001 |

Other services (Immich :2283, Uptime Kuma :3002, Filebrowser :8081) use the same port on both sides.

## Non-obvious constraints

- **Immich `.env` is not committed** (contains the Postgres password). It must be present at `immich/.env` before `docker compose up`. The Postgres image is pinned to a specific digest — do not casually bump it; follow Immich's upgrade guide.
- **`open-webui` named volume must be created before first run:** `docker volume create open-webui`. It is declared `external: true` and compose will fail if it doesn't exist.
- **Jellyfin config is at `/opt/docker/jellyfin/`**, not under `~/docker/jellyfin/` — only the compose file lives there.
- **All linuxserver.io images run as PUID/PGID 1000** — the `/mnt/data/media` and `/mnt/data/torrents` trees must be owned by uid/gid 1000.
- **dotfiles/scripts/server/** contains older or alternate versions of some compose files (open-webui, immich, filebrowser, pihole, homepage). The canonical files are in `~/docker/`. The dotfiles copies are kept for reference/templating; do not run them directly. This CLAUDE.md itself lives at `dotfiles/scripts/server/docker-CLAUDE.md` and is symlinked as `~/docker/CLAUDE.md`.
- **Immich backup** (`immich-backup.sh`) requires `/mnt/immich-backup` to be a mounted USB drive. It dumps Postgres via `docker exec pg_dumpall | gzip` and rsyncs the library with a monthly `.deleted-YYYYMM` backup dir. Retention: 7 days for DB dumps, 30 days for deleted-file dirs.
- **Pi-hole** binds to `0.0.0.0:53` — the host must not have `systemd-resolved` stub listener active on port 53.
- **WireGuard watchdog** (`wg-watchdog.sh`) runs as a background loop and restarts `wg0.service` if the VPN endpoint or Tailscale coordination becomes unreachable.
