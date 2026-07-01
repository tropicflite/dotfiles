# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Version Control

`~/docker/` is a private git repo. Commit compose file and config changes here after making them:

```bash
git -C ~/docker add -A && git -C ~/docker commit -m "message" && git -C ~/docker push
```

**Note:** runtime files (logs, databases, media covers) may show up as modified in `git status` — these should not be committed.

### Deploying host-level config

`pihole/cron.d/pihole` is the weekly gravity update cron job. Deploy it with:

```bash
sudo cp ~/docker/pihole/cron.d/pihole /etc/cron.d/pihole
```

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
- `pihole-compose` — After docker (starts before wg0 so br-pihole exists when wg0-up-extra.sh runs)
- `qbittorrent-compose` — After docker, tailscaled, wg0, mnt-data
- `radicale-compose` — After docker
- `tsdproxy-compose` — After docker, arrs-compose, immich-compose

**ntfy** (`~/docker/ntfy/`) has no systemd unit — `restart: unless-stopped` handles restarts and Docker auto-starts it on daemon boot. Manage directly from `~/docker/ntfy/`:
```bash
docker compose up -d
docker compose down
docker compose pull && docker compose up -d
```

Tailscale Serve rules are also managed by systemd units (`tailscale-serve-*.service`) so they survive tailscaled restarts. Current units (post-tsdproxy migration, see below): `tailscale-serve-homepage`, `tailscale-serve-drivetemps`. Everything else that used to be on Tailscale Serve has moved to tsdproxy (per-service Tailscale hostnames) — see the **tsdproxy** section below.

Radicale (`~/docker/radicale/`) and ntfy bind directly to the Tailscale interface IP (`100.65.250.53:<port>`) instead of using a Tailscale Serve rule — no HTTPS termination/proxy involved, just a host port restricted to the tailscale0 interface. ntfy is also on tsdproxy now (`ntfy-1.tailc9871d.ts.net`) — see below.

### tsdproxy — per-service Tailscale hostnames

**Why this exists (2026-06-30):** Proton Pass does not support port-level URL matching — it normalizes saved logins to the root domain, so when many services shared `server.tailc9871d.ts.net` differentiated only by port, Pass couldn't tell them apart for autofill and always suggested every saved login for that hostname. [tsdproxy](https://github.com/almeidapaulopt/tsdproxy) fixes this by giving each service its own real Tailscale hostname (`https://bazarr.tailc9871d.ts.net`, `https://radarr.tailc9871d.ts.net`, etc.) instead of a shared hostname + port.

**How it works:** `~/docker/tsdproxy/` runs a single container (`tsdproxy-compose.service`) that watches Docker for containers labeled `tsdproxy.enable=true`, and for each one spins up a lightweight virtual Tailscale node (via the `tsnet` library) with automatic Let's Encrypt HTTPS tied to that node's MagicDNS name. No host port is needed on the target container — tsdproxy reaches it directly over the Docker network (joins `arrs` + `immich_default`; Pi-hole is the one exception, reached via `host.docker.internal` fallback since `pihole_net` is intentionally isolated).

**Label convention**, added to the target service in its own compose file:
```yaml
labels:
  tsdproxy.enable: "true"
  tsdproxy.name: "bazarr"
  tsdproxy.port.1: "443/https:6767/http"   # container-internal port, not the host-published port
```

**Auth key:** `~/docker/tsdproxy/config/tsdproxy.yaml` is committed (references `authKeyFile: /config/authkey`); the actual key lives in `~/docker/tsdproxy/config/authkey`, gitignored, permissions 600. It's a reusable, non-ephemeral, untagged Tailscale auth key (90-day expiry — only matters for *new* node registrations, doesn't affect already-registered nodes). To rotate: generate a new key at `https://login.tailscale.com/admin/settings/keys`, overwrite the file, restart the container.

**Dashboard:** `https://tsdproxy.tailc9871d.ts.net` (also on tsdproxy itself, 2026-07-01 — it labels its own container). Still also reachable at `127.0.0.1:8180` on loopback (moved off tsdproxy's default 8080 — qBittorrent already owns that port on loopback).

**Known quirks:**
- The image is distroless (no `/bin/sh`, no `wget`/`curl`/`cat`/`ls` inside it) — don't add a `CMD-SHELL` healthcheck override; the image's own baked-in `/healthcheck` binary (exec-form, 60s interval) works fine and needs no override.
- New tsnet nodes sometimes land in a transient `NeedsLogin state without an auth URL` state right after creation, or hit ACME cert-issuance contention when several nodes register concurrently — both are usually self-healing within a minute, or resolved by `docker restart tsdproxy`.
- If a node's cert generation gets stuck for good (data dir has only `certs/acme-account.key.pem`, never a `.crt`/`.key` pair — check via `sudo ls ~/docker/tsdproxy/data/default/<name>/certs/`), this looks like Let's Encrypt's failed-validation rate limit (5 failures/hour/hostname). `docker restart tsdproxy` does NOT fix this (only helps genuinely-transient stuck states); the actual remedy is stopping tsdproxy, `sudo rm -rf ~/docker/tsdproxy/data/default/<name>/`, restarting tsdproxy, then force-recreating the target container so tsdproxy sees a fresh "container started" event (it does not rescan already-running containers on its own startup). This still may not clear immediately if the rate-limit window keeps getting refreshed by repeated attempts — sometimes the only fix is waiting it out (hours), untouched.
- Uptime Kuma (and any Node.js-based monitor) can cache stale container IPs across a batch of container recreations on the same Docker network — if several arr-stack-style containers get recreated together and end up with reshuffled IPs, Kuma's monitors may cross-wire (checking service A's old IP, which is now service B) until Kuma itself is restarted to clear its DNS cache.

**Migration status (2026-07-01): all 15 originally-planned services are on tsdproxy hostnames.** Their old Tailscale Serve rules/units are fully decommissioned — `tailscale serve status` now shows only Homepage and drivetemps. The last 4 (ntfy, immich, open-webui, pihole) were stuck on the Let's Encrypt rate limit described above for roughly 6+ hours; they cleared on their own after being left alone (no further intervention after the earlier data-dir-wipe attempt) rather than from any specific fix — supports "just wait it out" as the right remedy for this failure mode.

All 15 services now use clean bare-name hostnames. The 4 that were rate-limited initially landed on suffixed names (`ntfy-1`, etc.) because their old tsnet identities were still registered as orphaned offline devices in Tailscale — fixed 2026-07-01 by deleting the 4 offline duplicates from `https://login.tailscale.com/admin/machines`, then repeating the stuck-node remedy above (stop tsdproxy, `rm -rf` the 4 data dirs, restart tsdproxy, force-recreate the 4 target containers). All 4 reissued certs under their clean names within about a minute once the name conflict was gone.

**Cleanup pass (2026-07-01):** the now-redundant `127.0.0.1:<port>:<port>` host-port bindings, left over from the Tailscale-Serve era, were dropped from Radarr, Sonarr, Prowlarr, Bazarr, Jellyseerr, qBittorrent, and Stirling PDF's compose files — nothing depended on them once tsdproxy took over (tsdproxy reaches these containers directly over the `arrs` network by internal port, not through a host-published one). Jellyseerr keeps its LAN-direct binding (`192.168.50.34:5055:5055`); everything else lost its loopback port entirely. Still deferred: switching tsdproxy's Tailscale auth from a reusable auth key to OAuth (would require the tailnet's first-ever ACL/`tagOwners` policy — bigger blast radius, needs a deliberate separate pass).

## Architecture

### Networks

There are four named Docker networks:

| Network | Bridge | Subnet | Purpose |
|---------|--------|--------|---------|
| `arrs` | (default) | — | Shared by arrs stack, jellyfin, qbittorrent, homepage, uptime-kuma, ntfy, and stirling-pdf; allows inter-container name resolution |
| `pihole_net` | `br-pihole` | `172.25.0.0/24` | Isolated bridge for Pi-hole; NAT'd through wg0 via iptables |
| `qbittorrent` | `br-qbittorrent` | `172.27.0.0/24` | Isolated bridge for qBittorrent; hard iptables kill switch + software kill switch if wg0 goes down |
| `uptime-kuma_default` (alias `kuma`) | — | — | Immich joins this so Uptime Kuma can probe it |

**qBittorrent kill switch:** Two-layer protection. (1) **Hard iptables block**: `wg0-up-extra.sh` inserts `iptables -I FORWARD -s 172.27.0.0/24 ! -o wg0 -j DROP` — packets from the qBittorrent bridge are kernel-dropped immediately if wg0 is down. Rule persists via netfilter-persistent and is re-applied on every wg0 restart. Rule is NOT removed when wg0 goes down (intentional). (2) **Software kill switch**: `vpn-diskcheck.sh` runs every 5 minutes via cron, pings `1.1.1.1` through wg0, and stops the qbittorrent container (with email alert) if the VPN is down.

**Pi-hole routing through VPN:** `wg0-up-extra.sh` (runs as `ExecStartPost` of `wg0.service`) adds FORWARD rules for `br-pihole ↔ wg0` and NAT-masquerades `172.25.0.0/24` through wg0.

### Volume conventions

Most config and data is bind-mounted, not in named volumes:

- Stack-local config: `./service/config` inside the stack directory (e.g. `arrs/prowlarr/config`)
- Shared media tree: `/mnt/data/media/{movies,tv}` — mounted into Radarr, Sonarr, Bazarr, Jellyfin, qBittorrent, and Filebrowser
- Torrent paths: `/mnt/data/torrents/{downloads,incomplete}` — mounted into Radarr, Sonarr, and qBittorrent
- Immich library: `/mnt/data/immich/library` (set via `UPLOAD_LOCATION` in `immich/.env`)
- Immich Postgres: `/var/lib/immich/postgres` on NVMe (set via `DB_DATA_LOCATION` in `immich/.env`; moved off sdb 2026-05-28 after sdb journal recovery wiped the DB)
- Jellyfin config/cache: `/opt/docker/jellyfin/{config,cache}` (not under `~/docker`)
- Filebrowser root: `/mnt/data` (entire data mount, mounted as `/srv`)
- `open-webui` data: named Docker volume `open-webui` (external — must exist before `docker compose up`)
- Immich ML models: named Docker volume `immich_model-cache` (auto-created by compose, not external)
- Uptime Kuma data: `/home/matt/docker/uptime-kuma` (compose working dir, not a subdirectory)

### Service relationships

- **Prowlarr** is the indexer manager; Radarr and Sonarr pull indexers from it via the `arrs` network.
- **Radarr/Sonarr** send completed downloads to qBittorrent and import from `/mnt/data/torrents`. They are on both the `arrs` network and share the same `/mnt/data` mount tree as qBittorrent.
- **Bazarr** handles subtitles for Radarr/Sonarr content; mounts `/mnt/data/media` but not the torrents path.
- **Jellyseerr** is the request front-end; it talks to Jellyfin, Radarr, and Sonarr by container name over `arrs`.
- **Radarr/Sonarr/Prowlarr/Bazarr** publish no host port at all (hardened 2026-06-30 to `127.0.0.1` only, then the loopback binding itself was dropped 2026-07-01 since nothing used it) — reached only via their own tsdproxy hostnames (`radarr.tailc9871d.ts.net`, etc.) or by container name over `arrs`. **Jellyseerr** is the one exception, keeping a LAN-direct binding (`192.168.50.34:5055:5055`) alongside its tsdproxy hostname.
- **FlareSolverr** provides Cloudflare bypass for Prowlarr; runs on `:8191`.
- **Jellyfin** uses `/dev/dri/renderD128` for Intel GPU hardware transcoding (group `992` = render group) and is on the `arrs` network so Jellyseerr can reach it by name.
- **Open WebUI** connects to Ollama on the desktop machine via Tailscale IP `100.78.51.10:11434` (not a local container). TTS is provided by a co-located `openai-edge-tts` sidecar.
- **Homepage** joins the `arrs` network so it can contact arrs-stack services by container name for its widgets. It also mounts the Docker socket read-only for container status.
- **Uptime Kuma** is on both `uptime-kuma_default` and `arrs` networks. It uses `host.docker.internal:host-gateway` to probe host-bound ports. Immich joins `uptime-kuma_default` so Kuma can probe it by container name. Homepage reaches the widget API at `http://uptime-kuma:3001` over arrs. Monitors for arr-stack services + qBittorrent + stirling-pdf use container-name URLs over `arrs` (e.g. `http://radarr:7878`), not host-bound ports — those services (except Jellyseerr) publish no host port at all anymore. Editing monitors directly via `kuma.db` requires stopping the container first (matches `~/bin/reset-uptime-kuma.sh`'s pattern) since Kuma only reads monitor config from the DB at startup.
- **Filebrowser** binds to `127.0.0.1:8081` (Tailscale-Serve-era loopback port, no longer served — kept for local access) and `0.0.0.0:8089` for direct LAN access; reached remotely via its tsdproxy hostname (`filebrowser.tailc9871d.ts.net`).
- **ntfy** is the push notification server (`~/docker/ntfy/`). It runs on port 2586 and joins the `arrs` network so Homepage and Uptime Kuma can reach it at `http://ntfy:2586` by container name. Topic: `server-alerts`. Auth: `deny-all` — admin user is `matt`. All alert scripts in dotfiles send to ntfy alongside email; they read the password from `~/.config/ntfy/password`. The `nut` user (UPS scripts) reads from `/etc/nut/ntfy-password` instead. No Tailscale Serve rule — bound directly to the Tailscale interface IP at `http://100.65.250.53:2586` (hardened 2026-06-30; previously bound `0.0.0.0`, reachable from the LAN too).
- **Radicale** is a CardDAV/CalDAV server (`~/docker/radicale/`) for contacts/calendar sync. Bound directly to the Tailscale interface IP at `100.65.250.53:5232`, not via Tailscale Serve. Hardened compose config: `read_only`, `cap_drop: ALL` with minimal `cap_add` (CHOWN/SETUID/SETGID/KILL), `no-new-privileges`, `pids_limit`/`mem_limit`. Data at `/mnt/data/radicale`; users/config bind-mounted read-only from `~/docker/radicale/`.
- **drivetemps** is a custom Python container (`~/docker/homepage/drivetemps/server.py`) that serves a JSON API on host port 7778 (container port 7777). It reports CPU usage + temp, NVMe temp + root disk usage, sda (USB backup) temp + usage, sdb (Immich library) temp + usage, and RAM usage — read from `/hostfs` (root filesystem mounted read-only), smartctl, and `/proc`. Homepage uses it for its system stats widget. Exposed via `tailscale-serve-drivetemps.service` at `https://server.tailc9871d.ts.net:7777`. Excluded from Watchtower (`com.centurylinklabs.watchtower.enable=false`) because it is a locally built image.
- **autoheal** watches for unhealthy containers and restarts them automatically. Runs with `network_mode: "none"` and only targets containers labeled `autoheal=true`. Check interval: 10 seconds. Lives in the `pihole` compose file (`~/docker/pihole/docker-compose.yml`).
- **docker-health-monitor** is a systemd service (`docker-health-monitor.service`) running `~/bin/docker-health-monitor.sh` as user matt. It watches `docker events` for `health_status: unhealthy` transitions and immediately sends ntfy + email alert. Fires before autoheal acts, surfacing container flapping that would otherwise be silent. Script deployed to `/usr/local/bin/docker-health-monitor.sh`.
- **recyclarr** syncs TRaSH Guides quality profiles and custom formats into Radarr and Sonarr. Config: `~/docker/recyclarr/config/recyclarr.yml`. On the `arrs` network to reach radarr and sonarr by container name. Manual sync: `docker exec recyclarr recyclarr sync`. No internal cron — triggered by host cron at 3am daily via `~/bin/recyclarr-sync.sh`, which logs to `/var/log/recyclarr.log` and sends ntfy + email on failure.

### Access

All services are accessed over Tailscale. The server's Tailscale hostname is `server.tailc9871d.ts.net` (IP `100.65.250.53`). Pi-hole and Homepage have `restart: unless-stopped` and are started by systemd services on boot.

**Tailscale Serve is now only used by Homepage and drivetemps:**

| Service | Tailscale external port | Container internal port |
|---------|------------------------|------------------------|
| Homepage | root (:443) | 3001 |
| drivetemps | 7777 | 7778 |

Homepage's Serve rule used to also expose `:3000`, but that rule had no backing systemd unit (a "ghost" rule — would vanish on the next `tailscaled` restart/reboot). Dropped 2026-07-01 in favor of the root domain as the one durable HTTPS path; `HOMEPAGE_ALLOWED_HOSTS` and `rebuild.md`'s checklist were updated to match. Homepage's plain-HTTP LAN/loopback access (`http://100.65.250.53:3001` or any LAN IP, since it binds `0.0.0.0:3001:3000`) is unrelated to Serve and unaffected.

Every other service previously on Tailscale Serve (Jellyfin, qBittorrent, Stirling PDF, Scrutiny, Radarr, Sonarr, Prowlarr, Bazarr, Jellyseerr, Uptime Kuma, Filebrowser, ntfy, Immich, Open WebUI, Pi-hole) now uses a tsdproxy hostname instead — no Tailscale/Docker port-conflict concerns for these since tsdproxy talks to the container directly over the Docker network, not through a host-published port. Radicale (:5232) is the one remaining service bound straight to the Tailscale interface IP, bypassing both Serve and tsdproxy.

## Non-obvious constraints

- **Immich `.env` is not committed** (contains the Postgres password). It must be present at `immich/.env` before `docker compose up`. The Postgres image is pinned to a specific digest — do not casually bump it; follow Immich's upgrade guide.
- **`open-webui` named volume must be created before first run:** `docker volume create open-webui`. It is declared `external: true` and compose will fail if it doesn't exist.
- **Jellyfin config is at `/opt/docker/jellyfin/`**, not under `~/docker/jellyfin/` — only the compose file lives there.
- **All linuxserver.io images run as PUID/PGID 1000** — the `/mnt/data/media` and `/mnt/data/torrents` trees must be owned by uid/gid 1000.
- **dotfiles/scripts/server/** contains older or alternate versions of some compose files (open-webui, immich, filebrowser, pihole, homepage). The canonical files are in `~/docker/`. The dotfiles copies are kept for reference/templating; do not run them directly. This CLAUDE.md itself lives at `dotfiles/scripts/server/docker-CLAUDE.md` and is symlinked as `~/docker/CLAUDE.md`.
- **dotfiles/scripts/server/ systemd unit files are stale** — do not copy them to `/etc/systemd/system/` on a reinstall. The installed canonical versions are in `~/docker/systemd/`. Known divergences: all five `tailscale-serve-*.service` files in dotfiles have a `wg0.service` dependency that was dropped from the installed versions; `homepage-compose.service` and `open-webui-compose.service` differ in their `After=` and `Requires=` lines. Always use `~/docker/systemd/` as the source of truth for systemd units.
- **Immich backup** (`immich-backup.sh`) requires `/mnt/immich-backup` to be a mounted USB drive. It dumps Postgres via `docker exec pg_dumpall | gzip` and rsyncs the library with a monthly `.deleted-YYYYMM` backup dir. Retention: 7 days for DB dumps, 30 days for deleted-file dirs.
- **Pi-hole** binds to `0.0.0.0:53` — the host must not have `systemd-resolved` stub listener active on port 53.
- **WireGuard watchdog** (`wg-watchdog.sh`) runs as a background loop and restarts `wg0.service` if the VPN endpoint or Tailscale coordination becomes unreachable.
- **SSH/network watchdog** (`ssh-watchdog.sh`) runs as a background loop (`ssh-watchdog.service`) and reboots the server after 5 consecutive failed checks (~5 minutes). Checks: TCP connect to `localhost:22` (sshd accepting), and ping to LAN gateway `192.168.50.1` via `enp1s0`. If only sshd is down it attempts `systemctl restart ssh` before counting the failure. Added 2026-05-26 to recover from the recurring state where the server becomes unreachable via both Tailscale and LAN SSH without a kernel hang.
- **Tailscale/Docker port conflict:** when a service's Tailscale serve external port equals its Docker host port, Tailscale binds the Tailscale IP on that port at boot — before Docker starts the container. If Docker binds `0.0.0.0`, it fails. Fix: use `127.0.0.1:<port>:<container-port>` in the compose `ports` directive. Tailscale serve proxies to `localhost:<port>` which reaches the loopback binding. This concern no longer applies to services migrated to tsdproxy (all of them now, except Homepage/drivetemps) since tsdproxy reaches containers directly over the Docker network rather than through a host-published port — those services still need a shared Docker network (`arrs`/`immich_default`) if another container needs to reach them by name (e.g. Homepage's widgets), but not for tsdproxy itself.
- **tsdproxy'd services with no host port at all:** Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent, and Stirling PDF no longer publish any host port (2026-07-01 cleanup — the `127.0.0.1:<port>:<port>` bindings were dead weight once tsdproxy took over). They're reachable only via their tsdproxy hostname or by container name over `arrs`/`qbittorrent` networks. If you ever need host-level access again (e.g. `curl localhost:<port>` from the server itself for debugging), it won't work anymore — use `docker exec` or the tsdproxy hostname instead.
- **qBittorrent 5.x WebUI auth:** the `WebUI\AuthSubnetWhitelistEnabled` bypass (currently `172.20.0.0/16`) is required for the Homepage widget; qBittorrent 5.x CSRF protection returns 403 on the login endpoint for non-whitelisted IPs. If the widget breaks after a network change, check that the Homepage container's arrs IP is covered by the whitelist CIDR.
- **ntfy password files:** two copies must be kept in sync. `~/.config/ntfy/password` (matt:matt 600) is used by scripts running as matt or root. `/etc/nut/ntfy-password` (root:nut 640) is used by `upssched-cmd` which runs as the `nut` user. If the password is rotated, update both: `echo 'newpass' > ~/.config/ntfy/password && sudo sh -c 'cat /home/matt/.config/ntfy/password > /etc/nut/ntfy-password'`.
- **Router stats pipeline:** Homepage has a custom router stats widget that works via a three-part chain: (1) `router-stats.timer` fires `router-stats.service` every minute, which SSHes to the ASUS Merlin router (`ssh router /jffs/scripts/router-stats.sh`) and writes the JSON output to `~/router-stats/router-stats.json`; (2) `router-stats-http.service` runs `python3 -m http.server 9797 --directory ~/router-stats` so the file is reachable on the host at `:9797`; (3) Homepage fetches from `http://host.docker.internal:9797/router-stats.json` for its widget. If the router is unreachable the fetch silently no-ops and leaves the previous JSON in place.
- **update-uptime.py mutates services.yaml live:** A cron job (`* * * * *`) runs `~/bin/update-uptime.py`, which reads `/proc/uptime` and patches the `description:` field under the "Server Uptime" entry in `~/docker/homepage/config/services.yaml` in-place every minute. Homepage polls the file and reflects the change without a restart. Because this file is tracked in the docker git repo, do not `git reset --hard` or `git checkout` on the docker repo while the server is running — it will revert the uptime value.
- **Monitoring scripts and email pipeline:** See `~/docker/monitoring.md` for the full reference: health-monitor, temp-monitor, vpn-diskcheck, server-check, ups-charge-log, msmtp/Migadu email setup, and the complete cron schedule.

## Troubleshooting

### Immich ML unhealthy after unclean shutdown

**Symptom:** `immich_machine_learning` reports unhealthy; health checks time out (ping endpoint accepts connection but never responds); container logs show gunicorn started but no worker boot message.

**Cause:** An unclean shutdown (power loss, forced kill) leaves stale HuggingFace download `.lock` files in the `model-cache` volume. On restart the worker deadlocks trying to acquire them.

**Fix:**
```bash
docker exec immich_machine_learning find /cache -name '*.lock' -delete
docker restart immich_machine_learning
```
