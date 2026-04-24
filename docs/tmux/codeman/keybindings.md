# Codeman — keybindings

All of these fire **in the web UI** (browser tab), not in tmux.

## Session management

| Keys | Action |
|------|--------|
| `Ctrl+Enter`    | Quick-start new session |
| `Ctrl+W`        | Close current session |
| `Ctrl+Tab`      | Next session |
| `Alt+1`–`Alt+9` | Jump to tab N |
| `Ctrl+Shift+R`  | Restore terminal size |

## Inside the xterm.js terminal
The terminal forwards keys straight to the PTY — claude's own bindings work as usual (`Ctrl+C`, `Shift+Tab` for permission-mode cycle, `/compact`, `/clear`, `/init`, etc.).

## Mobile keyboard accessory bar
Tapping the accessory bar gives you one-tap buttons for:
- `/init`
- `/clear`
- `/compact`

Plus swipe left/right for session switching.

## `sc` CLI (non-web)

| Command | Action |
|---------|--------|
| `sc`      | Interactive picker |
| `sc N`    | Attach to session N |
| `sc -l`   | List sessions |

## Tmux bindings
Codeman doesn't inject custom tmux bindings — the point is you drive it from the web UI. Standard tmux keys still work inside the container if you attach directly.
