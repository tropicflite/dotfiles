#!/usr/bin/env bash
# SessionStart hook (matcher: clear) — loads and consumes a pending handoff
# written by the /handoff command, so /clear picks it up automatically.
set -euo pipefail

handoff="$HOME/.claude/handoff.md"
[[ -f "$handoff" ]] || exit 0

content=$(cat "$handoff")
rm -f "$handoff"

jq -n --arg ctx "$content" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ("Handoff from previous session:\n\n" + $ctx)}}'
