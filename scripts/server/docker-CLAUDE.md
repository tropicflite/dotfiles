# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Version Control

`~/docker/` is a private git repo. Commit compose file and config changes here after making them:

```bash
git -C ~/docker add -A && git -C ~/docker commit -m "message" && git -C ~/docker push
```

**Note:** runtime files (logs, databases, media covers) may show up as modified in `git status` — these should not be committed.

## Managing Stacks

All stacks follow the same pattern. From the stack's directory:

```bash
docker compose up -d          # start
docker compose down           # stop
docker compose pull && docker compose up -d  # update
docker compose logs -f        # tail logs
docker compose logs -f <svc>  # logs for one service
```

Most stacks are managed by systemd services (so they start on boot). Unit files live in `~/docker/systemd/` and are installed to `/etc/systemd/system/`. Use `sudo systemctl start|stop|restart <name>-compose` rather than bare `docker compose` for these:

- `arrs-compose` — After docker, wg0, mnt-data
- `filebrowser-compose` — After docker, wg0, mnt-data
- `homepage-compose` — After docker, tailscaled, mnt-data
- `immich-compose` — After docker, wg0, mnt-data
- `jellyfin-compose` — After docker, tailscaled, mnt-data
- `open-webui-compose` — After docker, tailscaled
- `pihole-compose` — After docker, wg0
- `qbittorrent-compose` — After docker, tailscaled, wg0, mnt-data

Tailscale Serve rules are also managed by systemd units (`tailscale-serve-*.service`) so they survive tailscaled restarts. Current units: `tailscale-serve-homepage`, `tailscale-serve-openwebui`, `tailscale-serve-uptime-kuma`.

## Architecture

### Networks

There are four named Docker networks:

| Network | Bridge | Subnet | Purpose |
|---------|--------|--------|---------|
| `arrs` | (default) | — | Shared by arrs stack, jellyfin, qbittorrent, homepage, and uptime-kuma; allows inter-container name resolution |
| `pihole_net` | `br-pihole` | `172.21.0.0/24` | Isolated bridge for Pi-hole; NAT'd through wg0 via iptables |
| `qbittorrent` | `br-qbittorrent` | `172.22.0.0/24` | Isolated bridge for qBittorrent; software kill switch stops container if wg0 goes down |
| `uptime-kuma_default` (alias `kuma`) | — | — | Immich joins this so Uptime Kuma can probe it |

**qBittorrent kill switch:** `vpn-diskcheck.sh` runs every 5 minutes via cron, pings `1.1.1.1` through wg0, and stops the qbittorrent container (with email alert) if the VPN is down. There is no iptables hard block — it is a software kill switch with up to a 5-minute gap.

**Pi-hole routing through VPN:** `wg0-up-extra.sh` (runs as `ExecStartPost` of `wg0.service`) adds FORWARD rules for `br-pihole ↔ wg0` and NAT-masquerades `172.21.0.0/24` through wg0.

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
- **Uptime Kuma** is on both `uptime-kuma_default` and `arrs` networks. It uses `host.docker.internal:host-gateway` to probe host-bound ports. Immich joins `uptime-kuma_default` so Kuma can probe it by container name. Homepage reaches the widget API at `http://uptime-kuma:3001` over arrs.
- **Filebrowser** binds only to `127.0.0.1:8081` — exposed externally via Tailscale Serve/Funnel or a reverse proxy, not directly.

### Access

All services are accessed over Tailscale. The server's Tailscale hostname is `server.tailc9871d.ts.net` (IP `100.65.250.53`). Pi-hole and Homepage have `restart: unless-stopped` and are started by systemd services on boot.

**Tailscale Serve port mappings** — several services use a different external port than the container port. Do not confuse these when editing `services.yaml` or compose files; the `href` in Homepage must use the Tailscale (external) port:

| Service | Tailscale external port | Container internal port |
|---------|------------------------|------------------------|
| Jellyfin | 8097 | 8096 |
| Pi-hole | 8090 | 8091 |
| qBittorrent | 8082 | 8080 |
| Homepage | 3000 | 3001 |
| Stirling PDF | 8085 | 8084 |

Other services (Immich :2283, Open WebUI :8083, Uptime Kuma :3003, Filebrowser :8081) use the same Tailscale external port as their Docker host port.

## Non-obvious constraints

- **Immich `.env` is not committed** (contains the Postgres password). It must be present at `immich/.env` before `docker compose up`. The Postgres image is pinned to a specific digest — do not casually bump it; follow Immich's upgrade guide.
- **`open-webui` named volume must be created before first run:** `docker volume create open-webui`. It is declared `external: true` and compose will fail if it doesn't exist.
- **Jellyfin config is at `/opt/docker/jellyfin/`**, not under `~/docker/jellyfin/` — only the compose file lives there.
- **All linuxserver.io images run as PUID/PGID 1000** — the `/mnt/data/media` and `/mnt/data/torrents` trees must be owned by uid/gid 1000.
- **dotfiles/scripts/server/** contains older or alternate versions of some compose files (open-webui, immich, filebrowser, pihole, homepage). The canonical files are in `~/docker/`. The dotfiles copies are kept for reference/templating; do not run them directly. This CLAUDE.md itself lives at `dotfiles/scripts/server/docker-CLAUDE.md` and is symlinked as `~/docker/CLAUDE.md`.
- **Immich backup** (`immich-backup.sh`) requires `/mnt/immich-backup` to be a mounted USB drive. It dumps Postgres via `docker exec pg_dumpall | gzip` and rsyncs the library with a monthly `.deleted-YYYYMM` backup dir. Retention: 7 days for DB dumps, 30 days for deleted-file dirs.
- **Pi-hole** binds to `0.0.0.0:53` — the host must not have `systemd-resolved` stub listener active on port 53.
- **WireGuard watchdog** (`wg-watchdog.sh`) runs as a background loop and restarts `wg0.service` if the VPN endpoint or Tailscale coordination becomes unreachable.
- **SSH/network watchdog** (`ssh-watchdog.sh`) runs as a background loop (`ssh-watchdog.service`) and reboots the server after 5 consecutive failed checks (~5 minutes). Checks: TCP connect to `localhost:22` (sshd accepting), and ping to LAN gateway `192.168.50.1` via `enp1s0`. If only sshd is down it attempts `systemctl restart ssh` before counting the failure. Added 2026-05-26 to recover from the recurring state where the server becomes unreachable via both Tailscale and LAN SSH without a kernel hang.
- **Tailscale/Docker port conflict:** when a service's Tailscale serve external port equals its Docker host port (currently open-webui :8083 and uptime-kuma :3003), Tailscale binds the Tailscale IP on that port at boot — before Docker starts the container. If Docker binds `0.0.0.0`, it fails. Fix: use `127.0.0.1:<port>:<container-port>` in the compose `ports` directive. Tailscale serve proxies to `localhost:<port>` which reaches the loopback binding. Services that other containers need to reach (e.g. uptime-kuma for Homepage's widget) must also join a shared Docker network so they can be addressed by container name instead of `host.docker.internal`.
- **qBittorrent 5.x WebUI auth:** the `WebUI\AuthSubnetWhitelistEnabled` bypass (currently `172.20.0.0/16`) is required for the Homepage widget; qBittorrent 5.x CSRF protection returns 403 on the login endpoint for non-whitelisted IPs. If the widget breaks after a network change, check that the Homepage container's arrs IP is covered by the whitelist CIDR.
