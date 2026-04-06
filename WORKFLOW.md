# Dotfiles & Package Sync Workflow

## Installing a New Program

1. `sudo apt install <package>` on laptop
2. `cd ~/dotfiles/packages && ./packages-push <package>` to add to master list and push
3. Configure the program how you like on laptop
4. Copy the config file into the dotfiles repo (e.g. `cp ~/.config/ranger/rc.conf ~/dotfiles/ranger/`)
5. Replace the original with a symlink (e.g. `ln -sf ~/dotfiles/ranger/rc.conf ~/.config/ranger/rc.conf`)
6. `dotp` to commit and push
7. On each other machine: `dotl` then `cd ~/dotfiles/packages && ./packages-pull`
8. Create the config symlink manually on each machine (first time only)
9. If a machine shouldn't have the package, add it to `packages/packages-ignore.<machine>` and commit/push

## Removing a Program Globally

1. `cd ~/dotfiles/packages && ./packages-remove <package>`
2. This removes it locally, adds it to `packages-removed.txt`, and pushes
3. On each other machine: `dotl` then `./packages-pull` to uninstall it

## Syncing a Machine
```bash
dotl && cd ~/dotfiles/packages && ./packages-pull
```

## Package Files Reference

| File | Purpose |
|------|---------|
| `packages/packages.txt` | Master list of packages for all machines |
| `packages/packages-removed.txt` | Packages to be removed from all machines |
| `packages/packages-ignore.<machine>` | Per-machine exclusions |
| `packages/packages-push` | Add a package to the master list |
| `packages/packages-pull` | Sync this machine to the master list |
| `packages/packages-remove` | Remove a package globally |

## Non-apt Installs (manual/curl)

These are not tracked by apt and must be handled separately in the init script:

- **oh-my-zsh** — curl install script
- **zsh-autosuggestions / zsh-syntax-highlighting** — cloned into oh-my-zsh custom plugins
- **Neovim AppImage** (mini only) — downloaded from GitHub releases
- **Nerd Fonts** — downloaded and installed to `~/.local/share/fonts`
- **Tailscale** (non-MX machines) — `curl -fsSL https://tailscale.com/install.sh | sh`
- **fastfetch** (Ubuntu/desktop) — PPA: `sudo add-apt-repository ppa:zhangsongcui3371/fastfetch`
- **Kitty** (laptop/mini) — downloaded from GitHub releases

## Machine Reference

| Hostname | OS | Username | Notes |
|----------|----|----------|-------|
| laptop | MX Linux 25.1 | matt | Reference machine |
| mini | MX Linux 25.1 | matt | No AVX, SysVinit, Bay Trail |
| desktop | Ubuntu 24.04 (WSL2) | matt | Windows host handles Tailscale |
| phone | GrapheneOS (Termux) | — | Pending setup |
| server | Debian 13 trixie | matt | Excluded from package sync |

## Termux (Phone) Notes

- Termux hostname is `localhost` — the sync scripts detect Termux via `$PREFIX` and use `phone` as the machine name instead
- Termux does not use `sudo` — scripts handle this automatically
- Termux has its own package repo; many packages from the master list are in `packages-ignore.phone`
- Package manager is `apt` but packages are Termux-specific builds, not Debian/Ubuntu packages

## Fleet Management
The dotfiles repo is synced across all machines using two core functions defined in `.zshrc`:

- `dotl` — pulls latest dotfiles on the current machine (`git fetch --prune --force origin && git pull`)
- `dotp [message]` — adds, commits, and pushes all changes (`git add -A && git commit -m "..." ; git push`)
- `fdotl` — runs `dotl` on all machines via SSH; detects if running locally to avoid self-SSHing; reminds to run `dotl` manually on phone

### fdotl behavior
- Runs `dotl` locally if hostname matches
- SSHes to mini/laptop as `matt@<host>`
- SSHes to server as `matt@server -p 28901`
- SSHes to desktop as `simin@desktop` and runs `wsl zsh -i -c dotl`
- Phone is excluded — run `dotl` manually in Termux

### Typical workflow
1. Make changes to dotfiles on any machine
2. `dotp "description"` to commit and push
3. `fdotl` to propagate to all machines

## Scripts Directory Structure
Scripts live in `~/dotfiles/scripts/` with per-machine subdirectories:

| Directory | Purpose |
|-----------|---------|
| `scripts/fleet/` | Scripts that run on all machines |
| `scripts/laptop/` | Laptop-specific scripts |
| `scripts/desktop/` | Desktop-specific scripts |
| `scripts/mini/` | Mini-specific scripts |
| `scripts/server/` | Server-specific scripts |
| `scripts/phone/` | Phone/Termux-specific scripts |

Scripts are symlinked into PATH using `scripts-link` (in `scripts/fleet/`). Run `scripts-link` after adding a new script to make it executable from anywhere.
