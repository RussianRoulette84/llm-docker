# Recon — troubleshooting

## `/clear` shows stale data
**Symptom:** after running `/clear` in a Claude Code session, recon still shows old tokens and old timestamps for that session.

**Why:** Claude Code's `/clear` creates a new JSONL file without updating the session-to-process mapping in `~/.claude/sessions/{PID}.json`. Recon is reading the old mapping.

**Fix:** kill the session in recon (`x`) and create a new one (`n`).

## Recon binary not found after `cld -tr`
- Confirm `INSTALL_TMUX_RECON=true` in [src/llm-docker.conf:86](../../../src/llm-docker.conf#L86)
- Confirm the auto-rebuild actually ran — check `cld` output for the rebuild log
- Inside the container: `ls ~/.cargo/bin/recon /usr/local/bin/recon`
- If still missing, rebuild the image manually

## Popup opens empty / "no sessions"
Recon requires at least one claude session in the tmux server. Start one first (just run `claude` in any pane) and reopen the dashboard with `prefix g`.

## Status shows "Unknown"
Recon detects state by matching patterns in the tmux pane's status bar. If Claude Code's TUI changed its status bar strings (upgrade), recon's matcher may miss. Check upstream issues at https://github.com/gavraz/recon/issues.

## `park` doesn't actually restore everything
Park captures the session metadata and last conversation state. It does NOT resume in-flight tool calls — any mid-tool-call session will come back idle at the last checkpoint.

## Two agents with the same name
Recon uses name-based identity in the UI but PID underneath. Rename one via the new-session form (`n`) or kill and re-launch with `--name`.

## Conflict with claude-tmux or codeman
Not supported — `-tr`, `-tc`, `-tcl` are mutually exclusive per `cld` invocation. You'd need to run separate containers.
