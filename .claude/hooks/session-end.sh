#!/usr/bin/env bash
# SessionEnd hook — screenshot hygiene at the end of every Claude Code session:
#  1. Quest screenshots sent with `qshot` (server:~/qshots/, via qshot-clear).
#  2. Images attached in the chat for THIS session, which Claude Code stores
#     under /tmp/claude-<uid>/<project>/<session_id>/images/.
# Never fails the session: every step is best-effort.
set -uo pipefail

input=$(cat 2>/dev/null || true)

[[ -x "$HOME/bin/qshot-clear" ]] && "$HOME/bin/qshot-clear" --quiet

sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
# session ids are UUIDs; refuse anything else so the glob can't widen.
if [[ "$sid" =~ ^[0-9a-fA-F-]{8,}$ ]]; then
  for d in /tmp/claude-"$(id -u)"/*/"$sid"/images; do
    [[ -d "$d" ]] && rm -rf -- "$d"
  done
fi
exit 0
