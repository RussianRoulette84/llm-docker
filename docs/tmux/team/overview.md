# Team mode — overview

**Flag:** `cld -tt` / `cld --tmux-team [N]`
**Source:** built into `src/cld` — no external tool.

One container, multiple claude panes, shared filesystem and shared Claude session storage. The lead pane runs your default model; the **last pane always runs Haiku** for cheap/fast throwaway tasks.

## Why use it
- Run 2–4 parallel claude agents on the same repo without spinning up multiple containers
- All panes share `/root/Projects` mounts, the same `~/.claude` session dir, the same MCP servers
- Cheaper than `-tt` across containers: one container, one set of daemons

## What it is NOT
- Not a multi-container orchestrator — that's what you'd build with `docker compose` + multiple `cld` shells
- Not a session manager — use [recon/](../recon/) or [codeman/](../codeman/) for that
- Not a popup overlay — that's [claude-tmux/](../claude-tmux/)

## Visual cues
- **Orange powerline border** around the whole tmux layout = team mode is active
- **Pink border** = currently active (focused) pane

## Related
- [layouts.md](./layouts.md) — the four pane arrangements
- [usage.md](./usage.md) — how to launch it
- [keybindings.md](./keybindings.md) — pane navigation
- [troubleshooting.md](./troubleshooting.md) — common issues
