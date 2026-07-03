---
name: close
description: >-
  Close out the current working session on Matt's homelab: fold durable
  learnings into the file-based memory system, correct or retire stale
  memory notes found along the way, check for uncommitted changes across
  any repos touched (dotfiles, docker, others), close out any open session
  tasks, then report a short session summary, close stats, and an honest
  prioritized debrief (audit? confidence? likely bugs? blast radius? what
  we missed?). Use whenever the user says "/close", "close the session",
  "close this out", "wrap up", "end of session", "session close", or asks
  to make sure memory/tasks/commits are squared away before stopping. Not
  for closing files, windows, PRs, or GitHub issues.
---

# Session close

Land everything this session learned into the memory system at
`/home/matt/.claude/projects/-home-matt/memory/`, make sure nothing's left
half-done across the repos touched, and debrief honestly. There's no MCP
memory server here — memory is plain markdown files plus `MEMORY.md` as the
index, edited directly with Read/Write/Edit. There's also no wiki, no task
board, and no single project repo: work this session may have spanned
`~/dotfiles`, `~/docker`, live server state, or other fleet machines.

Work the phases in order. Phases 1–3 are quick and mostly silent; phase 4 is
the only substantial output — everything the user reads lands there.

## Phase 1 — Reconstruct what the session touched

Build a concrete inventory before writing anything:

- From the conversation: decisions made, conventions established or
  corrected, surprises/gotchas hit, plans vs. what actually happened, memory
  notes read or relied on (and whether they held up), commands run that
  changed live state (not just investigated it).
- From the filesystem: `git status --short` + `git diff --stat` in every repo
  actually touched this session (typically `~/dotfiles`, sometimes `~/docker`
  — check both if unsure rather than assuming). Note anything staged,
  committed-but-unpushed, or dirty.
- `ls -lat ~/.claude/projects/-home-matt/memory/*.md | head` as a rough
  cross-check against what you think you wrote/edited — catches a memory
  write that silently failed or landed somewhere unexpected.

## Phase 2 — Memory hygiene

**Record durable learnings.** For each decision, fix, or convention worth
keeping beyond this conversation, write or update a memory file following
the existing format (frontmatter `name`/`description`/`metadata.type` —
`user`/`feedback`/`project`/`reference` — then body with **Why:** / **How to
apply:** lines for feedback/project types). Add a one-line pointer to
`MEMORY.md`. Apply the exclusion list already in the memory instructions —
code conventions, git history, debugging recipes, and anything CLAUDE.md
already documents don't belong here. **A zero-note close is a valid close**:
if nothing this session rises above "the code/commit already says it,"
write nothing. A note manufactured to have something to report is corpus
debt — it dilutes future searches and adds one more thing to go stale.

**Correct as you go.** If a memory file turned out to be stale, wrong, or
superseded during this session (like `project_email_infra.md`'s dead ntfy.sh
fallback today), fix it now — don't leave a known-wrong note for the next
`/clear`'d session to trip over and re-discover the hard way.

**Note what was actually verified.** There's no tooling here to stamp
memories as reviewed, so do this in prose in the debrief instead: which
memory notes did the session rely on AND re-confirm against current code or
live state (name the file/command that confirmed it), versus which were read
and trusted without re-checking. This is the same spirit as citing evidence
for a claim — don't imply a note is fresh if it was only skimmed.

**Tasks.** If `TaskCreate`/`TaskUpdate` were used this session, make sure
nothing is left `in_progress` — mark done, or explicitly note what's still
open and why it wasn't finished.

**Repos.** Leave commits to the user's explicit ask, same as always — this
skill never runs `dotp`/`docp`/`git commit`/`git push` on its own. If a repo
was left dirty or committed-but-unpushed, that's a stats line and a debrief
item, not something to silently fix.

## Phase 3 — Nothing pending

Before reporting, check: no memory file left known-wrong, no orphaned
`in_progress` task, no plan or finding that only exists in chat when it
clearly should be a memory note per the criteria above. Fix what a direct
edit can fix now; report what genuinely needs the user's input.

## Phase 4 — The close report

This is the final message, in exactly this shape:

### Session summary
Two to three sentences: what the session set out to do, what shipped, what
state it's in.

### Close stats
Short bulleted counts — only lines that are nonzero/relevant:
- Memory: notes written / edited / retired (name them)
- Verified vs trusted: memory notes re-confirmed against current state this
  session (with what confirmed them) · notes read but not re-verified
- Tasks: closed / left open (and why)
- Repos: commits made · pushed vs local-only · anything left dirty, per repo
- Fleet: any `dotl`/`fdotl`/`scripts-link` sync run, and which machines

### Debrief
Answer every bullet, in this priority order, against actual evidence from
the session — cite the file, command, or test that backs each answer. A
confident-sounding non-answer is worse than "I don't know"; if the honest
answer is uncomfortable (audit needed, low confidence, scope crept), say it
plainly.

- **Fresh-eyes audit?** Yes/no + the one-line why. For anything with real
  blast radius (live infra, secrets, force-pushes, anything touching the
  alert pipeline) or where the same session both wrote and checked its own
  work, lean yes — `/code-review ultra` is the concrete mechanism if there's
  a git diff to point it at.
- **Confidence.** High/medium/low, and the single thing that would most
  raise it.
- **Likely bugs / failure modes.** The concrete ways this could break, and
  where they'd first show up (an alert that doesn't fire, a script that
  silently no-ops, a fleet machine that didn't get the update). "None
  expected" needs a reason, not just an assertion.
- **Blast radius: plan vs. outcome.** Did the session stay inside what was
  asked? Name anything touched beyond that scope and why it was necessary.
- **Least confident right now.** The weakest spot — in this session's work,
  or in the underlying infra it touched.
- **Missed / now visible.** What the session missed, plus the biggest thing
  that's clearer now than when it started.
