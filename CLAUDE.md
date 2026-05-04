# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Manual dotfiles repo using git + custom shell functions for fleet-wide synchronization across 5 machines. No stow, chezmoi, or Nix — configs live in the repo and are symlinked into place by hand or via `dotfiles-setup`.

## Key Commands

### Fleet sync
```bash
dotl                    # git fetch + pull on current machine
dotp "message"          # git add -A + commit + push
fdotl                   # SSH to all machines and run dotl
dotclean                # remove stale git ref lock files (also runs automatically inside dotl)
```

### Initial setup on a new machine
```bash
~/dotfiles/scripts/fleet/dotfiles-setup   # creates all symlinks, installs ollama binary if needed
~/dotfiles/scripts/fleet/scripts-link     # symlinks scripts/ into ~/bin (run after adding new scripts)
```

### Package management (APT)
```bash
cd ~/dotfiles/packages
./packages-push <pkg>   # add installed package to master list, commit, push
./packages-pull         # sync this machine to master list (install missing, remove unwanted)
./packages-remove <pkg> # remove globally (adds to packages-removed.txt, commits, pushes)
```
Full sync: `dotl && cd ~/dotfiles/packages && ./packages-pull`

### Useful shell aliases (defined in `.zshrc`)
```bash
sauu          # sudo apt update && upgrade && autoremove (reports held packages)
sai / sar     # sudo apt install / remove
saa           # sudo apt autoremove
held          # show held packages
```

## Architecture

**Symlinks:** All configs live in `~/dotfiles/` and are symlinked to their expected locations. `dotfiles-setup` creates the links; new program configs must be symlinked manually after the first time.

**Machine detection:** Scripts use `${HOST%%.*}` lowercased as the machine name. Termux (phone) is detected via `$PREFIX` and uses `phone` as the name.

**Machine-specific config:** Each machine has `zsh/.zshrc.local.<machine>` for overrides (prompt name, Tailscale aliases, Ollama host, etc.) and `scripts/<machine>/` for machine-specific scripts. Any shell config that only applies to one machine (e.g. NVM on desktop) belongs in the local file, not `.zshrc`.

**Non-APT installs** are handled manually — see `WORKFLOW.md` for the list. Notable: Ollama client binary is auto-installed by `dotfiles-setup` (do NOT use `ollama.com/install.sh` — it installs a full server).

## Machine Reference

| Hostname | OS | Notes |
|----------|----|-------|
| laptop | MX Linux 25.1 | Reference machine; i3 + Kitty |
| mini | MX Linux 25.1 | No AVX, SysVinit, Bay Trail; i3 + Kitty |
| desktop | Ubuntu 24.04 (WSL2) | Ollama server (`100.78.51.10:11434`); `fdotl` reaches via `wsl zsh -i -c dotl` |
| server | Debian 13 trixie | Port 28901; excluded from package sync; runs Open WebUI + Docker |
| phone | GrapheneOS (Termux) | Manual `dotl` only; uses `$PREFIX` detection |

## Scripts Directory

```
scripts/fleet/      # runs on all machines (dotfiles-setup, scripts-link, dotclean)
scripts/laptop/
scripts/mini/
scripts/desktop/
scripts/server/     # Docker compose files, immich backup, Open WebUI config
scripts/phone/
```

All scripts are symlinked into `~/bin` by `scripts-link`. Run it after adding a new script.

## Adding a New Program Config

1. `sudo apt install <pkg>` → `./packages-push <pkg>`
2. Copy config into repo, replace original with symlink
3. `dotp "description"` to push
4. On other machines: `dotl` → `./packages-pull` → create symlink manually (first time)
5. To exclude a machine: add to `packages/packages-ignore.<machine>`

See `WORKFLOW.md` for full detail on all workflows.
