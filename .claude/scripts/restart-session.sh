#!/usr/bin/env bash
# Kills a claude process and respawns it in the given tmux pane, so the
# next session gets its own auto-generated title instead of /clear muddying
# the current session's topic history.
#
# Runs the full launch command directly rather than the `cld` alias: a
# long-lived pane's shell only has whatever alias definition was cached at
# shell startup, so if zshrc changes later (e.g. cld picks up a new flag),
# a stale pane would silently respawn with the old behavior. Keep this in
# sync with `alias cld` in zsh/.zshrc.local.{server,desktop}.
# Usage: restart-session.sh <claude_pid> <tmux_pane>
# Meant to be run backgrounded+disowned by the caller — this blocks ~2-8s.
set -uo pipefail

pid="$1"
pane="$2"

sleep 2
kill -TERM "$pid" 2>/dev/null || true

alive=1
for _ in 1 2 3 4 5; do
  kill -0 "$pid" 2>/dev/null || { alive=0; break; }
  sleep 1
done

if [[ "$alive" == "1" ]]; then
  kill -KILL "$pid" 2>/dev/null || true
  sleep 1
fi

tmux send-keys -t "$pane" "claude --dangerously-skip-permissions --remote-control" Enter
