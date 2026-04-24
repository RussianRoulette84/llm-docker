# Recon — overview

**Flag:** `cld -tr` / `cld --tmux-recon`
**Upstream:** [gavraz/recon](https://github.com/gavraz/recon) — MIT, Rust.

A tmux-native dashboard for managing multiple Claude Code sessions. Gives you a table view (and an optional "Tamagotchi" visual view) of every claude agent in your tmux, with one-key jumping between them.

## Why use it
- You run many parallel claude agents and lose track of which is **working** / **waiting for input** / **idle**
- Want `i` / `Tab` to jump to "the next agent that needs me"
- Want to `park` (serialize to disk) and `unpark` whole fleets of sessions

## Status detection
Recon reads each tmux pane's status bar to classify agents as:
- **Working** (claude is processing)
- **Input** (waiting on permission prompt)
- **Idle** (ready)
- **New** (just launched)

It also reads `~/.claude/sessions/{PID}.json` and `~/.claude/projects/.../*.jsonl` to map processes to projects.

## What it is NOT
- Not a web UI — that's [codeman/](../codeman/)
- Not a popup overlay — that's [claude-tmux/](../claude-tmux/)
- Not a multi-pane launcher — that's [team/](../team/)

## Related
- [install.md](./install.md) — how `cld` bakes it in
- [usage.md](./usage.md) — commands and views
- [keybindings.md](./keybindings.md) — table + Tamagotchi shortcuts
- [troubleshooting.md](./troubleshooting.md) — the `/clear` stale-data gotcha
