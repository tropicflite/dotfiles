---
description: Write a session handoff summary, auto-loaded after your next /clear
allowed-tools: Write
---

Write a concise handoff summary of this session to `~/.claude/handoff.md` (overwrite if it exists). Cover:

- The goal — what we're doing and why
- Key decisions made and the reasoning behind them
- Current state — what's done
- Next steps — what's left
- Any important facts, file paths, or gotchas a fresh session would need

Keep it dense and scannable — under 400 words, not exhaustive.

Then tell the user: "Handoff saved. Run /clear now to start fresh with it loaded."
