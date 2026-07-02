# Environment

- Server: OptiPlex 3060 Micro, Debian 13, SSH port 28901, Tailscale IP 100.65.250.53
- Shell: zsh, oh-my-zsh, dotfiles at ~/dotfiles/zsh/.zshrc
- Editor: nvim only, never nano
- Docker: ~/docker/, systemd units at ~/docker/systemd/
- Media: /mnt/data/media/tv/ and /mnt/data/media/movies/

# Conventions

- Dotfiles managed via `dotp` (commit+push) and `fdotl` (fleet pull on all machines)
- Docker repo (~/docker, server-only) managed via `docp` (same pattern as `dotp`, commit+push) — defined in `~/.zshrc.local.server`, not the shared `.zshrc`, since `~/docker` only exists there
- Machine-specific aliases in ~/.zshrc.local.<machine>
- All scripts go in ~/bin/
- Deliver all code/configs all-at-once, never piecemeal

# Key aliases

- `dotp` — git add -A + commit + push dotfiles
- `docp` — git add -A + commit + push ~/docker (server-only, `~/.zshrc.local.server`)
- `fdotl` — SSH to all machines and run dotl (fleet sync)
- `tserver` — SSH to server with tmux auto-attach
- `bz` — grep .zshrc

# Machine reference

| Hostname | OS | Notes |
|----------|----|-------|
| laptop | MX Linux 25.1 | Reference machine; i3 + Kitty |
| mini | MX Linux 25.1 | No AVX, SysVinit, Bay Trail |
| desktop | Ubuntu 24.04 (WSL2) | Windows host handles Tailscale |
| server | Debian 13 trixie | Port 28901; Docker host |
| phone | GrapheneOS (Termux) | Port 8022 |
| quest | Meta Quest (Termux) | Port 8022; Tailscale IP 100.74.113.62 |

# Stack

19 Docker containers including Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent,
Pi-hole, Immich, Homepage, Uptime Kuma. Tailscale handles HTTPS via
Serve for all services. ProtonVPN via wg0.service, split tunneling with
100.64.0.0/10 excluded.

See ~/docker/CLAUDE.md for full stack detail (networks, volumes, service
relationships, port mappings, non-obvious constraints).
See ~/docker/monitoring.md for monitoring scripts, alert thresholds, email pipeline (Migadu/msmtp), and cron schedule.
See ~/dotfiles/CLAUDE.md for dotfiles workflow detail.
