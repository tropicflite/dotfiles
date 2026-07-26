---
description: End this session's process and start a brand-new one in the same tmux pane (fresh title, no context carried)
allowed-tools: Bash
---

If `$TMUX_PANE` is not set (this session isn't running inside tmux), tell the user this only works inside a tmux session and stop — do not proceed.

Otherwise, run this in the background so it survives the current process dying:

```
nohup "$HOME/dotfiles/.claude/scripts/restart-session.sh" "$CLAUDE_PID" "$TMUX_PANE" >/tmp/claude-restart.log 2>&1 &
disown
```

Then tell the user: "Restarting — this session ends in ~2s, a fresh one starts in the same window (force-kill fallback after ~7s if needed). Reconnect Remote Control to pick it up."
