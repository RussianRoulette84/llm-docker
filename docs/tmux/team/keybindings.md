# Team mode — keybindings

All of these are **standard tmux** bindings — team mode doesn't add custom keys (that's recon's and claude-tmux's job). The `prefix` is `Ctrl+b` unless you rebound it.

## Pane navigation

| Keys | Action |
|------|--------|
| `prefix o`           | Cycle to next pane |
| `prefix ;`           | Toggle to last active pane |
| `prefix ↑/↓/←/→`     | Move focus in a direction |
| `prefix q`           | Show pane numbers (then press number to jump) |
| `prefix z`           | Zoom/unzoom active pane (fullscreen toggle) |

## Pane lifecycle

| Keys | Action |
|------|--------|
| `prefix x`           | Kill current pane (confirm) |
| `prefix !`           | Break pane into its own window |
| `prefix %`           | Split vertically (new pane to the right) |
| `prefix "`           | Split horizontally (new pane below) |

## Session

| Keys | Action |
|------|--------|
| `prefix d`           | Detach session (keep running) |
| `prefix &`           | Kill entire session (confirm) |
| `prefix s`           | List/switch sessions |

## Visual cue recap
- Orange powerline border = team mode active
- Pink border = focused pane

If you want fancier pane management (kill-by-name, search, resume picker), layer [recon/](../recon/) or [claude-tmux/](../claude-tmux/) on top — but remember the flags are mutually exclusive per launch, so pick at container-start time.
