# Recon — keybindings

## Tmux integration (baked into tmux.conf)

| Keys | Action |
|------|--------|
| `prefix g` | Open dashboard popup |
| `prefix n` | New-session form popup |
| `prefix r` | Resume picker popup |
| `prefix i` | Jump to next input-waiting agent |
| `prefix X` | Kill-session popup (with confirmation) |

`prefix` = `Ctrl+b` by default.

## Table view

| Keys | Action |
|------|--------|
| `j` / `k`          | Navigate sessions |
| `Enter`            | Switch to selected session |
| `/`                | Search/filter by name |
| `i` or `Tab`       | Jump to next input-waiting agent |
| `x`                | Kill selected session |
| `v`                | Switch to Tamagotchi view |
| `q` or `Esc`       | Quit |

## Tamagotchi view

| Keys | Action |
|------|--------|
| `1`–`4`            | Zoom into room 1–4 |
| `/`                | Search/filter |
| `j` / `k`          | Page navigation |
| `h` / `l`          | Select agent (when zoomed) |
| `Enter`            | Switch to agent (when zoomed) |
| `x`                | Kill agent (when zoomed) |
| `n`                | New session in current room (when zoomed) |
| `Esc`              | Zoom out / quit |
| `v`                | Switch back to table view |
| `q`                | Quit |

## The "next input" flow
`prefix i` (or `i`/`Tab` in table view) is the killer feature: recon scans every pane's status bar and jumps you to the first agent that's blocked on a permission prompt. If you run many parallel agents, this is the whole reason to use `-tr`.
