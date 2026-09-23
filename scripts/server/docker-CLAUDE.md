# CLAUDE.md

Each constraint below carries a one-line why. The incident history behind them lives in git log and in Claude's memory notes, not here.

## Version Control

`~/docker/` is a private git repo. Commit compose/config changes via `docp`:

```bash
docp "message"
# equivalent to: git -C ~/docker add -A && git -C ~/docker commit -m "message" && git -C ~/docker push
```

Runtime files (logs, databases, media covers) are gitignored. `homepage/config/services.yaml` is tracked but rewritten every minute by cron (see update-uptime.py under Non-obvious constraints), so a `docp` picks up whatever uptime value it currently holds.

### Deploying host-level config

`pihole/cron.d/pihole` is the weekly gravity update cron job: `sudo cp ~/docker/pihole/cron.d/pihole /etc/cron.d/pihole`

## Managing Stacks

```bash
docker compose up -d          # start
docker compose down           # stop
docker compose pull && docker compose up -d  # update
docker compose logs -f        # tail logs
docker compose logs -f <svc>  # logs for one service
```

Most stacks are managed by systemd units in `~/docker/systemd/` (installed to `/etc/systemd/system/`). For these, use `sudo systemctl start|stop|restart <name>-compose`, not bare `docker compose`:

- `arrs-compose` — After + Requires docker, wg0, mnt-data (deliberate: arr/indexer traffic is policy-routed through the VPN — no VPN, no arrs)
- `filebrowser-compose` — After docker, wg0, mnt-data; Requires docker + mnt-data only (so wg0 bounces don't take it down)
- `homepage-compose` — After docker, wg0, mnt-data, mnt-immich-backup, immich-compose; Requires docker, mnt-data, immich-compose (`immich_default` must exist or `up` fails). Deliberately does not Require mnt-immich-backup — the dashboard must survive a dead backup drive, since that's when you need it
- `immich-compose` — After docker, wg0, mnt-data; Requires docker + mnt-data only (a VPN bounce shouldn't take the photo library down)
- `jellyfin-compose` — After docker, tailscaled, mnt-data (tailscaled is a harmless Serve-era leftover)
- `ntfy-compose` — After docker, tailscale-ready, arrs-compose (arrs-compose creates the `arrs` network)
- `pihole-compose` — After docker (starts before wg0 so br-pihole exists when wg0-up-extra.sh runs). Its `ExecStartPost` re-runs `wg0-up-extra.sh` when wg0 is *already* up, restoring table 200's `172.25.0.0/24 dev br-pihole` route. This unit creates the bridge, so it is the only correct hook point — `docker.service` can't do it (it finishes starting before the bridge exists, and waiting there deadlocks). At boot wg0 is absent, so the hook no-ops and wg0's own PostUp does the full apply
- `qbittorrent-compose` — After docker, tailscaled, wg0, mnt-data; deliberately does NOT Require wg0 — VPN coupling is enforced by the kill switch + vpn-diskcheck, so wg0 bounces don't churn it
- `radicale-compose` — After docker, tailscale-ready, mnt-data
- `tsdproxy-compose` — After docker, arrs-compose, immich-compose (needs both external networks to exist)
- `watchtower-compose` — After docker
- `immich-ml-lockfix` — After/Requires immich-compose (not a compose unit: boot-time lockfile fix, see Troubleshooting)

Four stacks have no systemd unit — scrutiny, stirling-pdf, uptime-kuma, and nut-webgui rely on `restart: unless-stopped`. Manage those with bare `docker compose`.

`~/docker/systemd/` holds only the compose-stack units plus the two `tailscale-serve-*` units, and is their sole source of truth. Every other server unit (`wg0`, `ssh-watchdog`, `tailscale-ready` + selfheal, `nut-tailscale-listen`, `qbt-natpmp-renew`, `route-monitor`, and the monitoring units — `docker-health-monitor`, `healthcheck-ping`, `router-stats*`, `ups-charge-log`, `immich-ml-lockfix`) lives only in `~/dotfiles/scripts/server/`, mapped via `dotfiles.map` and verified weekly by `dotdrift`. One repo per unit — don't reintroduce duplicate copies in either direction; past mirrors silently went stale.

**`Requires=` propagation (verified 2026-07-02):** stopping a required unit stops its dependents (`docker compose down` — containers *removed*), and a later `start` of the dependency does **not** bring them back. A `systemctl restart` of the dependency propagates as a restart and dependents come back on their own. So: restart is safe (brief bounce); never plain-`stop` wg0 or tailscaled without expecting dependents to stay down until manually started. A wg0 restart bounces only the arrs stack (6 containers) — expect brief tsdproxy re-registration churn for the arr hostnames and possibly Uptime Kuma's stale-IP quirk.

### tailscale-ready.service

`tailscaled.service` is `Type=notify` and reports ready before `tailscale up` (in its `ExecStartPost`) has assigned the tailscale0 IP. `tailscale-ready.service` (`~/docker/systemd/tailscale-ready.service`, script `/usr/local/bin/wait-for-tailscale.sh`, tracked in `~/dotfiles/scripts/server/`) polls `tailscale ip -4` for up to 60s and exits 0 once it succeeds. **Any service that binds directly to the Tailscale IP (not via tsdproxy or Serve) must depend on `tailscale-ready.service`, not `tailscaled.service`, in both `After=` and `Requires=`.**

**`ntfy-compose` and `radicale-compose` both Require `tailscale-ready`**, so `sudo systemctl stop tailscaled` cascades and *removes* their containers, and nothing brings them back (this caused a 6+ hour undetected outage on 2026-07-01). `systemctl restart tailscaled` is fine (verified). After a stop, follow up with `sudo systemctl start ntfy-compose radicale-compose`.

**Self-heal timer:** a transient tailscaled restart can fail `tailscale-ready`'s start job and strand it — plus ntfy/radicale behind it — in `failed` with nothing retrying. `tailscale-ready-selfheal.timer` (5 min after boot, then every 15 min) restarts whichever of tailscale-ready/ntfy-compose/radicale-compose is `failed`, without touching the intentional Requires chain. Source in `~/dotfiles/scripts/server/`. If it seems inert, check the exec bit on `/usr/local/bin/tailscale-ready-selfheal.sh` first.

**`OnSuccess=` hook:** `tailscale-ready` fires `nut-tailscale-listen.service` on every successful run (boot and self-heal). `upsd` starts immediately on `127.0.0.1` + `172.20.0.1` without waiting for Tailscale, and re-reads `LISTEN` only on restart (not reload), so the hook restarts `nut-server` once to bring up the Tailscale-bound listener for the remote WinNUT client (no-op if already listening). It uses the safe sequence: stop `nut-monitor` first, restart it via an EXIT trap that fires even if the upsd restart fails (same pattern as `nut-apt-hook` — see the nut-server constraint below). dotdrift asserts the exec bit on everything it maps into `/usr/local/bin`.

Tailscale Serve rules are managed by `tailscale-serve-*.service` units so they survive tailscaled restarts. Only `tailscale-serve-homepage` and `tailscale-serve-drivetemps` remain; everything else is on tsdproxy.

Radicale and ntfy bind directly to the Tailscale interface IP (`100.65.250.53:<port>`) — a host port restricted to tailscale0, no proxy or TLS. ntfy is also on tsdproxy (`ntfy.tailc9871d.ts.net`); Radicale is not.

### tsdproxy — per-service Tailscale hostnames

**Why:** Proton Pass matches saved logins by root domain only, so services sharing `server.tailc9871d.ts.net` on different ports couldn't be told apart for autofill. [tsdproxy](https://github.com/almeidapaulopt/tsdproxy) gives each service its own real Tailscale hostname (`https://radarr.tailc9871d.ts.net`, etc.).

**How it works:** `~/docker/tsdproxy/` (`tsdproxy-compose.service`) watches Docker for containers labeled `tsdproxy.enable=true` and spins up a lightweight tsnet Tailscale node per container, with automatic Let's Encrypt HTTPS for its MagicDNS name. No host port is needed — it reaches targets over Docker networks (joins `arrs` + `immich_default`; Pi-hole is the exception, reached via `host.docker.internal` since `pihole_net` is intentionally isolated).

**Label convention**, added to the target service in its own compose file:
```yaml
labels:
  tsdproxy.enable: "true"
  tsdproxy.name: "bazarr"
  tsdproxy.port.1: "443/https:6767/http"   # container-internal port, not the host-published port
```

**Auth key:** `tsdproxy/config/tsdproxy.yaml` is committed (`authKeyFile: /config/authkey`); the key itself is `tsdproxy/config/authkey` (gitignored, 600) — reusable, non-ephemeral, untagged, 90-day expiry (only affects *new* node registrations). To rotate: generate a new key at `https://login.tailscale.com/admin/settings/keys`, overwrite the file, restart the container. Switching to OAuth is deliberately deferred (it would need the tailnet's first ACL/`tagOwners` policy).

**Dashboard:** `https://tsdproxy.tailc9871d.ts.net`; also `127.0.0.1:8180` on loopback (not the default 8080 — qBittorrent owns that port).

**Known quirks:**
- The image is distroless (no shell, curl, cat, ls) — don't add a `CMD-SHELL` healthcheck override; the baked-in exec-form `/healthcheck` binary works as is.
- New nodes can briefly sit in `NeedsLogin state without an auth URL`, or hit ACME contention when several register at once — usually self-heals within a minute, else `docker restart tsdproxy`.
- **Stuck cert** (data dir has only `certs/acme-account.key.pem`, never a `.crt`/`.key` pair — check `sudo ls ~/docker/tsdproxy/data/default/<name>/certs/`) usually means Let's Encrypt's failed-validation rate limit (5/hour/hostname). `docker restart tsdproxy` does NOT fix it. Remedy: stop tsdproxy, `sudo rm -rf ~/docker/tsdproxy/data/default/<name>/`, start tsdproxy, force-recreate the target container. If repeated attempts keep refreshing the rate-limit window, the real fix is leaving it untouched for hours — that's what cleared the last four services during the original migration.
- A node landing on a suffixed name (`ntfy-1`, etc.) means an old identity is still registered as an offline device — delete it at `https://login.tailscale.com/admin/machines`, then run the stuck-cert remedy above.
- Uptime Kuma (like any Node.js monitor) can cache stale container IPs when several containers on one network are recreated together, cross-wiring monitors until Kuma itself is restarted.

## Architecture

### Networks

Five Docker networks matter (other `*_default` networks are inert compose defaults):

| Network | Bridge | Subnet | Purpose |
|---------|--------|--------|---------|
| `arrs` | (default) | `172.20.0.0/16` | Shared by arrs stack, jellyfin, qbittorrent, homepage, uptime-kuma, ntfy, stirling-pdf, filebrowser, scrutiny, recyclarr, nut-webgui, and tsdproxy; allows inter-container name resolution |
| `pihole_net` | `br-pihole` | `172.25.0.0/24` | Isolated bridge for Pi-hole; NAT'd through wg0 via iptables |
| `qbittorrent` | `br-qbittorrent` | `172.27.0.0/24` | Isolated bridge for qBittorrent; hard iptables kill switch + software kill switch if wg0 goes down |
| `uptime-kuma_default` (alias `kuma`) | — | — | Immich joins this so Uptime Kuma can probe it |
| `immich_default` | — | — | Immich stack's own network; tsdproxy joins it to reach immich-server. Load-bearing for startup ordering: homepage-compose and tsdproxy-compose `Requires=`/`After=` immich-compose because this network must exist before they can `up` |

**qBittorrent kill switch** — two layers. (1) Hard block: `wg0-up-extra.sh` inserts `iptables -I FORWARD -s 172.27.0.0/24 ! -o wg0 -j DROP`; it persists via netfilter-persistent, is re-applied on every wg0 up, and is intentionally NOT removed when wg0 goes down. (2) Software: `vpn-diskcheck.sh` (cron, every 5 min) pings `1.1.1.1` through wg0 and stops the qbittorrent container (with email alert) if the VPN is down.

**qBittorrent inbound peers via ProtonVPN NAT-PMP:** `qbt-natpmp-renew.service` (source `~/dotfiles/scripts/server/qbt-natpmp-renew.sh`, dotfiles.map-managed) loops renewing a NAT-PMP mapping against Proton's gateway `10.2.0.1` — the lease is capped at 60s, hence the tight loop. Proton ignores the requested *public* port but honors the *private* port exactly and keeps the same public port across renewals, so the private port is fixed at 6881 (= qBittorrent's `listen_port`, never changes) and only the dynamic public port moves, flowing into qBittorrent's `announce_port`. The inbound rule (`wg0` → `172.27.0.2:6881` tcp+udp ACCEPT) is static in `wg0-up-extra.sh`; the renew script never touches iptables. qBittorrent's own `PortForwardingEnabled` and UPnP stay `false` — the host script does all forwarding.

**Pi-hole's own upstream DNS routes through ProtonVPN** (`br-pihole ↔ wg0` FORWARD/MASQUERADE in `wg0-up-extra.sh`) — privacy over reliability, Matt's explicit call (reaffirmed 2026-08-21). A direct-via-ISP variant (table 201) fixed Proton-flake DNS slowness for the whole LAN but let the upstream resolver see the household's queries from the home IP, so it was reverted — don't reintroduce it without asking. Upstream is currently `1.1.1.1`. History: `[[project_phone_exitnode_investigation_20260820]]`.

**Tailscale-client queries *to* Pi-hole** (`100.65.250.53:53`, separate from the above): DNAT + hairpin MASQUERADE to `172.25.0.2` proved fragile — conntrack never matched Pi-hole's reply, so every off-LAN Tailscale client silently lost DNS. Instead, `PREROUTING -i tailscale0 -s 100.64.0.0/10 --dport 53 -j RETURN` (ahead of the `-j DOCKER` ADDRTYPE-LOCAL jump) bypasses DNAT, so these fall through to local delivery via `docker-proxy`, the same path LAN queries use. Trade-off: Pi-hole's query log shows them as `127.0.0.1` (no per-client stats for Tailscale devices); filtering is unaffected.

### Volume conventions

Most config and data is bind-mounted, not in named volumes:

- Stack-local config: `./service/config` inside the stack directory (e.g. `arrs/prowlarr/config`)
- Shared media tree: `/mnt/data/media/{movies,tv}` — mounted into Radarr, Sonarr, Bazarr, Jellyfin, qBittorrent, and Filebrowser
- Torrent paths: `/mnt/data/torrents/{downloads,incomplete}` — mounted into Radarr, Sonarr, and qBittorrent
- Immich library: `/mnt/data/immich/library` (set via `UPLOAD_LOCATION` in `immich/.env`)
- Immich Postgres: `/var/lib/immich/postgres` on NVMe (set via `DB_DATA_LOCATION` in `immich/.env`; moved off sdb after an sdb journal recovery wiped the DB)
- Jellyfin config/cache: `/opt/docker/jellyfin/{config,cache}` (not under `~/docker`)
- Filebrowser root: `/mnt/data` (entire data mount, mounted as `/srv`)
- Immich ML models: named Docker volume `immich_model-cache` (auto-created by compose, not external)
- Uptime Kuma data: `/home/matt/docker/uptime-kuma` (compose working dir, not a subdirectory)

### Service relationships

- **Prowlarr** is the indexer manager; Radarr and Sonarr pull indexers from it over `arrs`.
- **Radarr/Sonarr** send completed downloads to qBittorrent and import from `/mnt/data/torrents`; they share `arrs` and the same `/mnt/data` tree as qBittorrent.
- **Bazarr** handles subtitles for Radarr/Sonarr content; mounts `/mnt/data/media` but not the torrents path.
- **Jellyseerr** is the request front-end; talks to Jellyfin, Radarr, and Sonarr by container name over `arrs`. Keeps a LAN-direct binding (`192.168.50.34:5055:5055`) alongside its tsdproxy hostname.
- **No host port at all:** Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent, Stirling PDF, and Scrutiny — reachable only via tsdproxy hostname or container name over `arrs`/`qbittorrent`. `curl localhost:<port>` from the server won't work; use `docker exec` or the tsdproxy hostname. (qBittorrent's inbound peers arrive via NAT-PMP straight to the container IP, not a host port.)
- **FlareSolverr** provides Cloudflare bypass for Prowlarr on `:8191`.
- **Jellyfin** uses `/dev/dri/renderD128` for Intel GPU hardware transcoding (group `992` = render) and is on `arrs` so Jellyseerr can reach it by name.
- **Homepage** joins `arrs` (static IP `172.20.0.250`) to reach arr services by name for widgets. Runs the stock `ghcr.io/gethomepage/homepage:latest` image and mounts only its own config + icons — no Docker socket, host mounts, raw devices, or extra caps (all removed as vestigial). CPU/drive stats come from the drivetemps sidecar, fetched browser-side by `custom.js`.
- **Uptime Kuma** is on `uptime-kuma_default` and `arrs`; uses `host.docker.internal:host-gateway` to probe host-bound ports. Homepage reaches its widget API at `http://uptime-kuma:3001`. Monitors for arr services + qBittorrent + stirling-pdf use container-name URLs over `arrs` (e.g. `http://radarr:7878`). Editing monitors directly in `kuma.db` requires stopping the container first (Kuma reads monitor config only at startup — see `~/bin/reset-uptime-kuma.sh`).
- **Filebrowser** binds `127.0.0.1:8081` (local access) and `0.0.0.0:8089` (LAN); remote via `filebrowser.tailc9871d.ts.net`.
- **ntfy** (`~/docker/ntfy/`) is the push notification server on port 2586, on `arrs` so Homepage/Kuma reach it at `http://ntfy:2586`. Topic `server-alerts`; auth `deny-all`, admin user `matt`. Bound to the Tailscale IP (`http://100.65.250.53:2586`) and `127.0.0.1:2586`, not the LAN. **Local scripts must target `localhost:2586`** — dropping that loopback binding once silently broke ten alert scripts.
- **Alert dispatch:** alert scripts delegate to `/usr/local/bin/send-alert` (ntfy only) or `/usr/local/bin/send-mail` (email + ntfy, for matching bodies) — never copy-paste ntfy curl/password logic into a new script. `send-alert` auto-detects the password file (`~/.config/ntfy/password` for matt/root, `/etc/nut/ntfy-password` for the nut user). **`send-alert` must be a real file copy, not a symlink** (`sudo cp ~/dotfiles/scripts/server/send-alert /usr/local/bin/send-alert && sudo chmod +x`) — the nut user can't traverse a symlink through `/home/matt` (700); same reason as `upssched-cmd`. `send-mail` stays symlinked (only called as matt/root). The *email* leg of every alert is deduped and batched by the alert-digest pipeline (`/usr/local/bin/msmtp` PATH shim + 15-min cron flush; ntfy stays instant) — read `~/docker/monitoring.md` before touching anything that sends mail.
- **Radicale** (`~/docker/radicale/`) is a CardDAV/CalDAV server bound directly to `100.65.250.53:5232`. Hardened: `read_only`, `cap_drop: ALL` with minimal `cap_add` (CHOWN/SETUID/SETGID/KILL), `no-new-privileges`, `pids_limit`/`mem_limit`. Data at `/mnt/data/radicale`; users/config bind-mounted read-only from `~/docker/radicale/`.
- **nut-webgui** (`~/docker/nut-webgui/`, [SuperioOne/nut_webgui](https://github.com/SuperioOne/nut_webgui)) is a read-only UPS dashboard talking to the host's `upsd`. `host.docker.internal` resolves to the default bridge gateway (`172.17.0.1`), not `arrs`'s — don't assume `host-gateway` follows a container's attached network — so `UPSD_ADDR` is hardcoded to the `arrs` gateway `172.20.0.1`, with a matching `LISTEN 172.20.0.1 3493` in `/etc/nut/upsd.conf`. (upsd listens on `127.0.0.1`, `100.65.250.53` for WinNUT, and `172.20.0.1` for this container.) Uses a dedicated read-only `webgui` user in `upsd.users`. Reached at `nut-webgui.tailc9871d.ts.net`.
- **drivetemps** is a custom Python container (`~/docker/homepage/drivetemps/server.py`) serving a JSON API on host port 7778 (container 7777): CPU usage + temp, NVMe temp + root usage, sda (USB backup) and sdb (Immich library) temp + usage, RAM — read from `/hostfs` (root fs, read-only), smartctl, and `/proc`. Feeds Homepage's system stats widget. Exposed via `tailscale-serve-drivetemps.service` at `https://server.tailc9871d.ts.net:7777`.
- **autoheal** restarts unhealthy containers labeled `autoheal=true` (10s interval, `network_mode: "none"`). Lives in `~/docker/pihole/docker-compose.yml`.
- **docker-health-monitor** (`docker-health-monitor.service`, `/usr/local/bin/docker-health-monitor.sh`, runs as matt) watches `docker events` for `health_status: unhealthy` and immediately sends ntfy + email — fires before autoheal acts, so flapping isn't silent.
- **recyclarr** syncs TRaSH Guides profiles/custom formats into Radarr and Sonarr (config `~/docker/recyclarr/config/recyclarr.yml`, on `arrs`). No internal cron — host cron runs `~/bin/recyclarr-sync.sh` at 03:00 daily (logs `/var/log/recyclarr.log`, ntfy + email on failure). Manual: `docker exec recyclarr recyclarr sync`.
- **watchtower** (`~/docker/watchtower/`) — two instances in one compose file, both `image: nickfedor/watchtower:latest` (the maintained fork; `containrrr/watchtower` is archived and frozen). Same `com.centurylinklabs.watchtower.*` labels and flags as upstream.
  - `watchtower-auto` (03:30, `WATCHTOWER_SCOPE: "auto"`, `WATCHTOWER_LABEL_ENABLE: "true"`) actually pulls + recreates, but only containers carrying both `com.centurylinklabs.watchtower.enable: "true"` and `com.centurylinklabs.watchtower.scope: "auto"`: radicale, prowlarr, radarr, sonarr, bazarr, jellyseerr, flaresolverr, qbittorrent, recyclarr, autoheal, jellyfin, scrutiny, stirling-pdf, filebrowser, uptime-kuma. Anything DNS/alerting/networking/backup-critical — pihole, ntfy, tsdproxy, homepage, immich_*, nut-webgui — stays review-then-manual (`docker compose pull && up -d` per stack).
  - `watchtower` (04:00, `WATCHTOWER_MONITOR_ONLY: "true"`, scope `"none"`) checks all non-excluded containers but never applies. `WATCHTOWER_ROLLING_RESTART` is incompatible with monitor-only.
  - **Scoping is mandatory while two instances run:** each instance's startup self-cleanup kills any other container from the same image unless it sees a different scope, and it reads the `com.centurylinklabs.watchtower.scope` *label* on siblings, not their env var. So each carries both the env var and a matching scope label on its own container (`"none"` / `"auto"`).
  - **Notify on failure only** (dark cockpit): both set `WATCHTOWER_NOTIFICATION_REPORT: "true"` plus a custom `WATCHTOWER_NOTIFICATION_TEMPLATE` (`{{- with .Report -}}{{- if .Failed -}}...{{- end -}}{{- end -}}`) that renders empty — and so sends nothing — unless `.Report.Failed` is non-empty. `WATCHTOWER_NOTIFICATIONS_LEVEL: "info"` is now cosmetic (it only gates `.Entries`, which the template ignores). `watchtower/.env`'s `WATCHTOWER_NOTIFICATION_URL` is shared by both via compose substitution.
  - **`drivetemps` must never get the enable/scope labels** — it's a locally built untagged image (`image: drivetemps`), so an "update" would pull an unrelated Docker Hub image by that name.
  - Under monitor-only, `com.centurylinklabs.watchtower.enable=false` suppresses *notifications*, not updates — so it marks only images where "update available" is meaningless: drivetemps and Immich's digest-pinned postgres/redis.

### Access

All services are accessed over Tailscale. Server hostname `server.tailc9871d.ts.net` (IP `100.65.250.53`). Pi-hole and Homepage have `restart: unless-stopped` and are started by systemd on boot.

**Tailscale Serve is only used by Homepage and drivetemps:**

| Service | Tailscale external port | Container internal port |
|---------|------------------------|------------------------|
| Homepage | root (:443) | 3001 |
| drivetemps | 7777 | 7778 |

Never add a Serve rule without a backing `tailscale-serve-*` unit — it vanishes on the next tailscaled restart.

Homepage's plain-HTTP `:3001` is bound to `127.0.0.1` only (no auth or TLS, so not on the LAN), kept as a fallback if Tailscale is down: `http://localhost:3001` on the server, or `ssh -L 3001:localhost:3001 server` from elsewhere. `HOMEPAGE_ALLOWED_HOSTS` is `localhost:3001,server.tailc9871d.ts.net` — keep it in sync with any change to Homepage's access paths.

Every other service uses a tsdproxy hostname; Radicale (:5232) has none and is reached only through its direct Tailscale-IP binding.

## Non-obvious constraints

- **Immich `.env` is not committed** (Postgres password). It must exist at `immich/.env` before `docker compose up`. The Postgres image is pinned to a digest — don't casually bump it; follow Immich's upgrade guide.
- **Gitignored secrets and where they're backed up:** `scrutiny/config/scrutiny.yaml` (ntfy password in its notify URL) → `docker-state-backup.sh` + monthly `secrets-backup` bundle; `radicale/users` (bcrypt htpasswd) → `secrets-backup`; `ntfy/data/` (`auth.db`) and Pi-hole's live runtime → `docker-state-backup.sh` (`pihole/backup/` Teleporter zips are gitignored redundant copies). Any new gitignored secret needs a backup home in one of these — several were once backed up nowhere.
- **Jellyfin config is at `/opt/docker/jellyfin/`**, not `~/docker/jellyfin/` — only the compose file lives there.
- **All linuxserver.io images run as PUID/PGID 1000** — `/mnt/data/media` and `/mnt/data/torrents` must be owned by uid/gid 1000.
- **`~/dotfiles/scripts/server/` holds older/alternate copies of some compose files** (immich, filebrowser, pihole, homepage) for reference only — canonical files are in `~/docker/`; don't run the dotfiles copies. This CLAUDE.md itself lives at `dotfiles/scripts/server/docker-CLAUDE.md`, symlinked as `~/docker/CLAUDE.md` — commit edits with `dotp`, not `docp`.
- **Immich backup** (`immich-backup.sh`) requires `/mnt/immich-backup` (USB drive) mounted. Dumps Postgres via `docker exec pg_dumpall | gzip` and rsyncs the library with a monthly `.deleted-YYYYMM` dir. Retention: 7 days for DB dumps, 30 days for deleted-file dirs.
- **Pi-hole binds `0.0.0.0:53`** — the host must not have the `systemd-resolved` stub listener on port 53.
- **Never restart/stop `nut-server.service` while `nut-monitor.service` is running.** Restarting `upsd` can make `upsmon` skip its `DEADTIME` grace and go straight to a forced `shutdown -h now` — this caused a real unplanned poweroff needing the physical power button. Safe sequence: `sudo systemctl stop nut-monitor`, make/verify the `nut-server` change, `sudo systemctl start nut-monitor`. The unattended-upgrades path is covered by `/etc/apt/apt.conf.d/99nut-safe-upgrade` → `/usr/local/bin/nut-apt-hook` (source `dotfiles/scripts/server/nut-apt-hook`), a `DPkg::Pre-Invoke`/`Post-Invoke` hook that stops/restarts `nut-monitor` around any `nut*` package. Deploy on rebuild per `rebuild.md` step 9.
- **`/etc/resolv.conf` has a hand-applied fallback line tracked nowhere:** `nameserver 192.168.50.1` (router), after the `127.0.0.1` (Pi-hole) that `/etc/network/interfaces` declares. A rebuild loses it unless re-added — see `rebuild.md` step 2.
- **WireGuard watchdog** (`wg-watchdog.sh`, `wg-watchdog.service`) doesn't touch systemd: a dead endpoint gets bare `wg-quick down/up`, Tailscale coordination loss gets `tailscale down/up` (avoiding the tailscaled Requires cascade). That's only safe because *all* wg0 routing (main-table default, endpoint pin, iptables, table 200) lives in `wg0-up-extra.sh`, which runs as wg0.conf's `PostUp` on every `wg-quick up` path. Keep it that way — routing added only to `wg0.service` gets silently dropped by a watchdog bounce (tunnel green, traffic leaking via the ISP, kill switch dead). `vpn-diskcheck.sh` has a route check for this.
- **wg0 helper scripts** (all in `~/dotfiles/scripts/server/`): `wg0-prestart.sh` waits for the Tailscale IP and caches the LAN default gateway to `/run/wg0-gateway`; `wg0-up-extra.sh` (PostUp) applies all routing + iptables; `wg0-down-extra.sh` removes the FORWARD/NAT rules on teardown. `route-monitor.service` journals every routing-table change (`ip -ts monitor route`) — first stop when a route silently disappears (`journalctl -u route-monitor`).
- **SSH/network watchdog** (`ssh-watchdog.sh`, `ssh-watchdog.service`) reboots the server after 5 consecutive failed checks (~5 min): TCP connect to `localhost:22` and ping to gateway `192.168.50.1` via `enp1s0`. If only sshd is down it tries `systemctl restart ssh` first. Exists to recover a recurring state where the server is unreachable via both Tailscale and LAN without a kernel hang.
- **Tailscale/Docker port conflict** (applies only to Serve-exposed services — Homepage, drivetemps): if a Serve external port equals the Docker host port, Tailscale binds the Tailscale IP on that port at boot before Docker starts the container, and a `0.0.0.0` Docker bind fails. Use `127.0.0.1:<port>:<container-port>`; Serve proxies to localhost.
- **qBittorrent 5.x WebUI auth:** `WebUI\AuthSubnetWhitelistEnabled` (currently `172.20.0.0/16`) is required for the Homepage widget — CSRF protection 403s the login endpoint for non-whitelisted IPs. If the widget breaks after a network change, check Homepage's arrs IP is inside the whitelist CIDR.
- **ntfy password files — two copies, keep in sync:** `~/.config/ntfy/password` (matt:matt 600, for matt/root scripts) and `/etc/nut/ntfy-password` (root:nut 640, for `upssched-cmd` as the nut user). On rotation: `echo 'newpass' > ~/.config/ntfy/password && sudo sh -c 'cat /home/matt/.config/ntfy/password > /etc/nut/ntfy-password'`.
- **Router stats pipeline:** `router-stats.timer` (every minute) → `router-stats.service` runs `ssh router /jffs/scripts/router-stats.sh` into `~/router-stats/router-stats.json` → `router-stats-http.service` serves it via `python3 -m http.server 9797` → Homepage fetches `http://host.docker.internal:9797/router-stats.json`. If the router is unreachable the fetch silently no-ops and the previous JSON stays.
- **update-uptime.py mutates services.yaml live:** cron (`* * * * *`) runs `~/bin/update-uptime.py`, patching the "Server Uptime" `description:` in `~/docker/homepage/config/services.yaml` every minute; Homepage picks it up without restart. Don't `git reset --hard` or `git checkout` the docker repo while the server is running — it reverts the uptime value.
- **Monitoring scripts and email pipeline:** see `~/docker/monitoring.md` (health-monitor, temp-monitor, vpn-diskcheck, server-health, ups-charge-log, msmtp/Migadu, full cron schedule).

## Troubleshooting

### Immich ML unhealthy after unclean shutdown

**Symptom:** `immich_machine_learning` reports unhealthy; health checks time out (ping endpoint accepts but never responds); logs show gunicorn started but no worker boot message.

**Cause:** an unclean shutdown leaves stale lockfiles that deadlock the worker. Two variants: HuggingFace download `.lock` files in the `model-cache` volume, and `/opt/venv/.lock` inside the container.

**Boot-time automation:** `immich-ml-lockfix.service` (runs after immich-compose) handles the `/opt/venv/.lock` variant — clears it and restarts the container up to 3 times until healthy (`~/bin/immich-ml-lockfix.sh`). Check `journalctl -t immich-ml-lockfix` before debugging by hand.

**Manual fix (HuggingFace variant):**
```bash
docker exec immich_machine_learning find /cache -name '*.lock' -delete
docker restart immich_machine_learning
```
