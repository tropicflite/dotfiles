---
description: Write a handoff, then end this session's process and start a fresh one that auto-loads it
allowed-tools: Write, Bash
---

First, write a concise handoff summary of this session to `~/.claude/handoff.md` (overwrite if it exists). Cover:

- The goal — what we're doing and why
- Key decisions made and the reasoning behind them
- Current state — what's done
- Next steps — what's left
- Any important facts, file paths, or gotchas a fresh session would need

Keep it dense and scannable — under 400 words, not exhaustive.

Then, if `$TMUX_PANE` is not set (this session isn't running inside tmux), tell the user this only works inside a tmux session and stop — do not proceed further.

Otherwise, run this in the background so it survives the current process dying:

```
nohup "$HOME/dotfiles/.claude/scripts/restart-session.sh" "$CLAUDE_PID" "$TMUX_PANE" >/tmp/claude-restart.log 2>&1 &
disown
```

Then tell the user: "Handoff saved, restarting — this session ends in ~2s, a fresh one starts in the same window with the handoff loaded. Reconnect Remote Control to pick it up."
