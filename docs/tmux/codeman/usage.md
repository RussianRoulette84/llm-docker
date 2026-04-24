# Codeman — usage

## Launch via `cld`
```bash
cld -tc          # Claude Code backend
ocd -tc          # OpenCode backend
```

`cld -tc` starts tmux, launches `codeman web`, and publishes port 3000 to the host. Open `http://localhost:3000` in your browser.

## Web UI flow
1. **Create a session** — `Ctrl+Enter` in the web UI, or use the `+` button
2. **Drive it** — type in the xterm.js terminal (zero-lag local echo)
3. **Park it** — close the tab; the tmux session keeps running
4. **Re-attach later** — reload the page, the session list restores from tmux

## Command-line selector (SSH-friendly)
```bash
sc              # Interactive session selector
sc 2            # Quick attach to session 2
sc -l           # List all sessions
```

Use `sc` from any terminal (including host SSH into the container) — it's the non-web path to the same sessions.

## HTTPS / remote access
```bash
codeman web --https
```
For real remote access, combine with:
- **Tailscale** (recommended VPN)
- **Cloudflare tunnel** — `cloudflared` + QR auth (tokens single-use, 60s expiry, 10-fail IP block for 15min)

## Respawn Controller
Enable a preset when creating the session:
- `solo-work` — single long-running agent
- `subagent-workflow` — parent + children
- `team-lead` — ensemble coordination
- `ralph-todo` — TodoWrite-driven loop
- `overnight-autonomous` — longest autonomy window

The controller detects idle states, runs `/clear` / `/init` cycles, and tracks health (0–100).

## Token management
- **110k tokens:** auto `/compact` summarizes context
- **140k tokens:** auto `/clear` + `/init` for a fresh start

## Mutually exclusive with
`-t`, `-tt`, `-tr`, `-tcl`. One tmux mode per container.
