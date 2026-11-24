# tropicflite's dotfiles

Manual dotfiles repo for a 7-machine fleet (laptop, mini, desktop/WSL2, server, phone, quest, burner). Configs live in the repo and are symlinked into place via `dotfiles-setup`. Fleet-wide sync is handled by `dotl` / `dotp` / `fdotl`. Package management uses a custom apt wrapper (`packages-push`, `packages-pull`, `packages-remove`). See `CLAUDE.md` for architecture and key commands, and `WORKFLOW.md` for step-by-step procedures.
