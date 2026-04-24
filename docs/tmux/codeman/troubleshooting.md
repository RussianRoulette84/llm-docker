# Codeman — troubleshooting

## Can't reach http://localhost:3000
- Confirm `cld -tc` actually started — look for the "codeman web" log line
- Confirm port 3000 is published by `cld` (should be automatic — see [src/cld](../../../src/cld))
- Is something else already bound to :3000 on the host? `lsof -i :3000` — kill or remap
- Firewall/VPN on the host blocking loopback? (rare, but check)

## High latency over VPN / SSH tunnel
This is what the zero-lag input overlay is for. It echoes keystrokes locally in 0ms and forwards to the PTY in 50ms batches. If you're still seeing lag:
- Make sure you're hitting the **web UI**, not raw SSH into the container
- Check that the overlay is enabled (default on)
- For typical Tailscale / Cloudflare tunnel RTTs (200–300ms) it should feel local

## QR auth fails / token expired
- Tokens expire after **60 seconds** — scan quickly
- Single-use — if you scanned once and it didn't complete, regenerate
- Rate limited: **10 failed attempts = 15-minute IP block**

## Respawn Controller keeps thrashing
The circuit breaker should catch this, but if respawns loop:
- Check health score (0–100) — if stuck low, pause the controller
- Inspect the preset — `overnight-autonomous` is the most aggressive; try `solo-work` instead

## Session not surviving container restart
Sessions persist via tmux, so they live as long as the tmux server inside the container lives. Container restart = tmux server gone = sessions gone. Mount `~/.codeman/` and `~/.claude/` as volumes to keep the metadata, but live PTYs won't survive a container stop.

## "Ghost" sessions appear after restart
Upstream's "ghost session discovery" picks up orphaned tmux sessions on startup. Expected behavior — not a bug. Clean them up from the UI's session list.

## Auto-`/compact` or auto-`/clear` surprised me
Thresholds are 110k (compact) and 140k (clear). If you want manual control, disable auto-threshold in the session settings and run `/compact` yourself.

## Mobile button taps register twice
Known upstream quirk with the 44px hit targets on some Android skins. Workaround: enable "click delay" in the UI settings.
