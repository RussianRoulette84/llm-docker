# Codeman — overview

**Flag:** `cld -tc` / `cld --tmux-codeman` (also `ocd -tc` for OpenCode)
**Upstream:** [Ark0N/Codeman](https://github.com/Ark0N/Codeman) — web UI control plane.

A **web** UI (`http://localhost:3000`) for managing claude (and OpenCode) agents running inside tmux. Biggest feature is the **Respawn Controller**: it detects idle agents and continues work unattended for 24+ hours.

## Why use it
- You want a browser tab instead of a terminal dashboard
- You want **remote / mobile access** with QR-code auth and zero-lag input overlay
- You want unattended overnight runs via built-in presets (`overnight-autonomous`, `ralph-todo`, `solo-work`, ...)
- You want per-session token + cost tracking with auto-`/compact` at 110k tokens and auto-`/clear` at 140k

## Core pieces
- Multi-session dashboard (up to 20 parallel)
- Live draggable terminal windows with animated parent→child connection lines
- xterm.js terminals at 60fps
- Respawn Controller with circuit breaker to prevent thrashing
- Mobile-optimized: swipe navigation, QR auth, safe-area support for notches
- TodoWrite progress tracking shown as `4/9 complete` rings

## What it is NOT
- Not a terminal TUI — that's [recon/](../recon/)
- Not a popup overlay — that's [claude-tmux/](../claude-tmux/)
- Not a multi-pane launcher — that's [team/](../team/)

## Related
- [install.md](./install.md) — baked-in install + manual install
- [usage.md](./usage.md) — web UI, `sc` selector, daemon modes
- [keybindings.md](./keybindings.md) — keyboard shortcuts in the UI
- [troubleshooting.md](./troubleshooting.md) — tunnels, auth, high-latency
