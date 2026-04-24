# Recon — usage

## Launch via `cld`

```bash
cld -tr
```

This starts a plain tmux session and opens the recon dashboard popup.

## Core commands

Run these from inside a tmux pane (or via the `prefix`-bound popups — see [keybindings.md](./keybindings.md)):

| Command | Action |
|---------|--------|
| `recon`                 | Table view dashboard (default) |
| `recon view`            | Tamagotchi visual dashboard |
| `recon json`            | Dump session data as JSON (for scripts) |
| `recon launch`          | Spawn a new claude session in the background |
| `recon new`             | Interactive new-session form |
| `recon resume`          | Interactive resume picker |
| `recon next`            | Jump to next agent awaiting input |
| `recon park`            | Serialize all live sessions to disk |
| `recon unpark`          | Restore parked sessions |

## `launch` — the flexible one

```bash
recon launch                                  # new session, auto name
recon launch --name reviewer --cwd ~/repos/app
recon launch --command "claude --model sonnet" --attach
```

`--attach` jumps straight into the new session instead of backgrounding it.

## Two views

- **Table** — compact list, fastest for jumping. Default.
- **Tamagotchi** — spatial "rooms" view, each room groups agents. Toggle with `v`.

## Mutually exclusive with
`-t`, `-tt`, `-tc`, `-tcl`. Pick one per container.

## Park / unpark
`recon park` writes every live session's state to disk so you can kill the tmux server (or reboot) and bring them all back with `recon unpark`. Useful for overnight work or laptop-sleep crossings.
