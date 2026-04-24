# claude-tmux — usage

## Launch via `cld`
```bash
cld -tcl
```

Starts tmux with claude running and the `prefix C-c` popup binding active.

## Summoning the popup
`prefix C-c` (default `Ctrl+b` then `Ctrl+c`) opens an 80×30 popup overlay listing every tmux session with its Claude status.

## Main flow
1. `prefix C-c` — popup appears
2. `j`/`k` (or arrows) — select session
3. `l` / `→` — expand details (live preview of the session's recent output)
4. `Enter` — switch to that session
5. Popup auto-dismisses on switch

## Creating sessions
Press `n` inside the popup → new-session form. Supports:
- Plain new session in `$CWD`
- **Git worktree** session: creates a worktree for a branch and starts claude in it

The worktree path is predictable (`../claude-<branchname>` relative to the repo root, per upstream convention).

## PR integration
After claude finishes work in a worktree, claude-tmux can push + open a PR via `gh`. Needs `gh auth login` done beforehand.

## Filtering
Press `/` to filter the session list as you type. `Ctrl+c` (inside the popup) clears the filter.

## Renaming + killing
- `r` — rename selected session
- `K` (capital) — kill selected session (no confirmation — watch out)
- `R` — refresh list (rarely needed; polling is automatic)

## Help overlay
Press `?` inside the popup for the built-in cheat sheet.

## Mutually exclusive with
`-t`, `-tt`, `-tr`, `-tc`. One tmux mode per container.
