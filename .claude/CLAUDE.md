# Environment

- Server: OptiPlex 3060 Micro, Debian 13, SSH port 28901, Tailscale IP 100.65.250.53
- Shell: zsh, oh-my-zsh, dotfiles at ~/dotfiles/zsh/.zshrc
- Editor: nvim only, never nano
- Docker: ~/docker/, systemd units at ~/docker/systemd/
- Media: /mnt/data/media/tv/ and /mnt/data/media/movies/

# Conventions

- Scripts live in the dotfiles repo (`~/dotfiles/scripts/<machine>/` or `scripts/fleet/`) and are symlinked into ~/bin by `scripts-link` — never create an untracked file directly in ~/bin. Server scripts installed outside `$HOME` (e.g. /usr/local/bin) also need a `scripts/server/dotfiles.map` entry in the same session
- Machine-specific aliases in ~/.zshrc.local.<machine>
- Deliver all code/configs all-at-once, never piecemeal

# Key aliases

- `dotp` — git add -A + commit + push dotfiles
- `dotl` / `fdotl` — pull dotfiles on this machine / SSH to all machines and run dotl (fleet sync)
- `docp` — git add -A + commit + push ~/docker (server-only; defined in `~/.zshrc.local.server`, not the shared `.zshrc`, since `~/docker` only exists there)
- `tserver` — SSH to server with tmux auto-attach
- `bz` — bat ~/.zshrc

# Machine reference

| Hostname | OS | Notes |
|----------|----|-------|
| laptop | MX Linux 25.1 | Reference machine; i3 + Kitty; SysVinit |
| mini | MX Linux 25.1 | No AVX, SysVinit, Bay Trail; i3 + Kitty |
| desktop | Ubuntu 24.04 (WSL2) | Port 22; Windows host handles Tailscale |
| server | Debian 13 trixie | Port 28901; Docker host |
| phone | GrapheneOS (Termux) | Port 8022 |
| quest | Meta Quest (Termux) | Port 8022; Tailscale IP 100.74.113.62 |

# Stack

27 Docker containers including Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent,
Pi-hole, Immich, Homepage, Uptime Kuma. Most services are exposed via tsdproxy
on per-service Tailscale hostnames; Tailscale Serve is only used directly for
Homepage (root domain, :443) and the Drive Temps API (:7777). ProtonVPN via
wg0.service, split tunneling with 100.64.0.0/10 excluded.

See ~/docker/CLAUDE.md for full stack detail (networks, volumes, service
relationships, port mappings, non-obvious constraints).
See ~/docker/monitoring.md for monitoring scripts, alert thresholds, email pipeline (Migadu/msmtp), and cron schedule.
See ~/dotfiles/CLAUDE.md for dotfiles workflow detail.
