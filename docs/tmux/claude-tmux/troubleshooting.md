# claude-tmux — troubleshooting

## `prefix C-c` does nothing
- Confirm the bind exists: `tmux show -g | grep 'C-c'` should show the display-popup line
- Re-source tmux config: `prefix :` → `source-file ~/.tmux.conf`
- Confirm the binary is on `PATH`: `which claude-tmux`
- Confirm `INSTALL_TMUX_CLAUDE=true` in [src/llm-docker.conf:88](../../../src/llm-docker.conf#L88) and rebuild if missing

## Popup appears but is empty
Means claude-tmux found zero tmux sessions (it lists sessions, not panes). Start at least one claude session first, then reopen.

## All statuses show `?`
The detector scrapes pane content for known prompt/interrupt patterns. If Claude Code's TUI changed its strings (upgrade), detection breaks.
- Check upstream issues: https://github.com/nielsgroen/claude-tmux/issues
- Workaround: trust the preview pane (`l` to expand) rather than the glyph

## Popup too small / cut off
Edit the `-w` and `-h` values in the tmux.conf bind-key line. Values are columns and rows, not pixels. Example: `-w 100 -h 40` for a bigger popup.

## Kill (`K`) happened by accident
No confirmation dialog by design — upstream decision. If this bites you, fork + patch, or avoid `K` and use `prefix :` + `kill-session` for safety.

## PR creation fails
- `gh` CLI missing inside the container — install with `apt-get install -y gh` or rebuild
- `gh auth login` never run — run it once; credentials persist in `~/.config/gh/`
- Push permission denied — check the remote's permissions; claude-tmux can't fix auth

## Worktree creation fails
- Repo isn't a git repo (no `.git` in cwd)
- Branch name collides with an existing worktree — `git worktree list`, clean up, retry
- Disk full or path permissions — check the sibling directory of your repo

## Popup conflicts with another `prefix C-c` binding
If you already bind `prefix C-c` for something (e.g. copy-mode), pick a different key in the `bind-key` line. Common free keys: `g`, `P`, `C-g`.
