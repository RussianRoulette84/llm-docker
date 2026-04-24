---
description: Implement a plan file from ~/.claude/plans or specs/
argument-hint: [path-to-plan]
allowed-tools: Read, Write, Bash, Edit, Glob, Grep
---

# Build (llm-docker)

Implement a plan file in this repo. Plans typically live at
`~/.claude/plans/*.md` (from `/plan`) or `specs/plan-*.md`.

## Variables

PATH_TO_PLAN: $ARGUMENTS

## Workflow

1. If no `PATH_TO_PLAN` provided, STOP and ask the user to point at one.
2. Read the plan at `PATH_TO_PLAN`. If a **Context** section exists, read it
   first so you understand *why* — don't just mechanically apply the diff.
3. Read every file the plan lists under "Files to modify" / "Critical files"
   before editing — CLAUDE.md rule: never delegate understanding.
4. Implement. Follow the plan's verdict on scope; don't silently expand.
5. After implementation, run the matching feedback-loop checks from
   `.claude/commands/agents_loops_extension.md` (syntax-check shell files,
   py_compile touched Python, grep for broken callers on renames).
6. If the plan has a **Verification** section, walk through it. Flag any
   step you CAN'T run (the user has denied git / docker autorun in this repo
   — see CLAUDE.md) and leave those for the user.

## Report

- Bullet list of what changed, grouped by file.
- `wc -l` diff isn't available without git; instead list the files you
  edited/created/deleted and 1-line intent per file.
- Any verification step you deferred to the user, and why.
