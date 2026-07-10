# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Manual dotfiles repo using git + custom shell functions for fleet-wide synchronization across 6 machines. No stow, chezmoi, or Nix — configs live in the repo and are symlinked into place by hand or via `dotfiles-setup`.

## Key Commands

### Fleet sync
```bash
dotl                    # git fetch + pull on current machine
dotp "message"          # git add -A + commit + push
fdotl                   # SSH to all machines and run dotl
dotclean                # delete packed-refs + origin/master ref so git refetches them (dotl inlines the same logic, doesn't call this directly)
```

### Initial setup on a new machine
```bash
~/dotfiles/scripts/fleet/dotfiles-setup   # creates all symlinks
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

**Symlinks:** All configs live in `~/dotfiles/` and are symlinked to their expected locations. `dotfiles-setup` creates the links; new program configs must be symlinked manually after the first time. `dotl` does a `git reset --hard`, so anything tracked in the repo is overwritten to match origin on every sync — never track machine-local or runtime-mutated files.

**Claude Code files:** `~/.claude/CLAUDE.md` is a symlink to the tracked `.claude/CLAUDE.md` (global instructions, fleet-synced), and `~/docker/CLAUDE.md` on the server is a symlink to the tracked `scripts/server/docker-CLAUDE.md` — edit those through either path, commit here. The live `~/.claude/settings.json` is git-ignored and machine-local because Claude rewrites it at runtime (`model` via `/model`, `theme` via `/config`, etc.); tracking it would churn the repo and `dotl`'s hard reset would silently wipe those writes. Shared defaults live in the tracked `.claude/settings.json.example`; `dotfiles-setup` merges that into the live file (example keys win, local-only keys like `model`/`theme` are preserved) and symlinks it into place. To change a shared default, edit the `.example` and re-run `dotfiles-setup` on each machine. `.claude/settings.local.json` (permissions allowlist) is also machine-local and git-ignored.

**Stale `~/bin` links:** `scripts-link` prunes broken symlinks that point back into `scripts/` before relinking, so renaming or deleting a script no longer leaves a dangling link behind.

**Machine detection:** Scripts use `${HOST%%.*}` lowercased as the machine name. Termux devices (phone, quest) are detected via `$PREFIX`; the logical name is read from `$PREFIX/etc/machine-name` (falls back to `phone` if missing).

**Machine-specific config:** Each machine has `zsh/.zshrc.local.<machine>` for overrides (prompt name, Tailscale aliases, etc.) and `scripts/<machine>/` for machine-specific scripts. Any shell config that only applies to one machine (e.g. NVM on desktop) belongs in the local file, not `.zshrc`.

**Non-APT installs** are handled manually — see `WORKFLOW.md` for the list.

## Drift Detection (server)

`scripts/server/dotfiles.map` maps everything this repo deploys on the server *outside* `$HOME` (systemd units, `/usr/local/bin` scripts, crontabs) from repo path to install path, with a type per entry: `symlink` (install path is a symlink into the repo), `copy` (root-owned copy installed via `sudo cp` — content is diffed), `copy-secret` (repo copy has secrets redacted — only existence is checked), `crontab` (diffed against the live crontab), and `exclude` (managed elsewhere, listed so the unmapped-file scan stays quiet). `dotdrift` (weekly cron, Mon 06:00, logs to `/var/log/dotdrift.log`) verifies every entry and flags unmapped files.

**Convention: when a new script or unit is installed outside `$HOME`, add its dotfiles.map entry in the same session** — don't rely on the weekly dotdrift run to catch it (a missing entry has already let a deployed script go untracked for a day; see fleet-update-digest, 2026-07-04).

## Machine Reference

| Hostname | OS | Notes |
|----------|----|-------|
| laptop | MX Linux 25.1 | Reference machine; i3 + Kitty |
| mini | MX Linux 25.1 | No AVX, SysVinit, Bay Trail; i3 + Kitty |
| desktop | Ubuntu 24.04 (WSL2) | `fdotl` reaches via `wsl zsh ~/dotfiles/scripts/fleet/dotl`; connects as `simin` (Windows-side account), not `matt` |
| server | Debian 13 trixie | Port 28901; excluded from package sync; runs Docker |
| phone | GrapheneOS (Termux) | Full `fdotl` member; port 8022; uses `$PREFIX` + machine-name detection |
| quest | Meta Quest (Termux) | Full `fdotl` member; port 8022; Tailscale IP `100.74.113.62` |

## Scripts Directory

```
scripts/fleet/      # runs on all machines (dotfiles-setup, scripts-link, dotclean)
scripts/laptop/
scripts/mini/
scripts/desktop/
scripts/server/     # server-only: monitoring/alerting scripts, systemd units + dotfiles.map,
                    # docker-CLAUDE.md, immich backup, reference copies of some compose files
scripts/phone/      # Termux baseline (shared by all Termux devices)
scripts/quest/      # quest-only overrides, layered on top of phone/
```

All scripts are symlinked into `~/bin` by `scripts-link`. Run it after adding a new script. On non-phone Termux devices (quest), `scripts-link` links `scripts/phone/` first as the shared baseline, then the device's own dir — so a same-named script in `scripts/quest/` overrides the phone version while everything else is shared.

## Adding a New Program Config

1. `sudo apt install <pkg>` → `./packages-push <pkg>`
2. Copy config into repo, replace original with symlink
3. `dotp "description"` to push
4. On other machines: `dotl` → `./packages-pull` → create symlink manually (first time)
5. To exclude a machine: add to `packages/packages-ignore.<machine>`

See `WORKFLOW.md` for full detail on all workflows.
