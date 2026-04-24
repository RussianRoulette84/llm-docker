# claude-tmux — keybindings

## Trigger
`prefix C-c` — open the popup. (`prefix` = `Ctrl+b` unless rebound.)

## Navigation inside the popup

| Keys | Action |
|------|--------|
| `j` / `↓`       | Move selection down |
| `k` / `↑`       | Move selection up |
| `l` / `→`       | Expand session details (preview pane) |
| `h` / `←`       | Collapse details |
| `Enter`         | Switch to selected session |

## Actions

| Keys | Action |
|------|--------|
| `n`             | Create new session (includes worktree option) |
| `K`             | Kill selected session (no confirmation) |
| `r`             | Rename selected session |
| `/`             | Filter sessions |
| `Ctrl+c`        | Clear active filter |
| `R`             | Force refresh list |
| `?`             | Show help overlay |
| `q` / `Esc`     | Quit / dismiss popup |

## Status glyph legend

| Glyph | Meaning |
|-------|---------|
| `●`   | Working — claude is actively processing |
| `○`   | Idle — ready for input |
| `◐`   | Waiting for input (permission prompt, etc.) |
| `?`   | Unknown — detector couldn't classify |

## Rebinding the popup
Change the tmux.conf line if you want a different trigger:
```tmux
bind-key g display-popup -E -w 80 -h 30 "~/.cargo/bin/claude-tmux"
```
Now it's `prefix g`. Reload tmux config: `prefix :` → `source-file ~/.tmux.conf`.

## Popup size
Width/height come from the `-w` and `-h` flags. Defaults (80×30) work on most screens; bump to `-w 100 -h 40` for big monitors.
