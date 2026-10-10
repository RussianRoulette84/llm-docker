#!/bin/sh
# session-hook.sh — Claude Code SessionStart hook (wired in by cld via --settings).
# Usage: session-hook.sh OUT_FILE
# Claude passes the hook input as JSON on stdin; this writes its session_id to
# OUT_FILE so the host launcher knows exactly which chat THIS tab is on. Fires on
# startup, resume, /clear and /compact, so the file always holds the live chat.
# Prints nothing on stdout: SessionStart stdout is injected into Claude's context.

out="$1"
if [ -z "$out" ]; then
    echo "Error: session-hook: missing output file argument" >&2
    exit 1
fi

sid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
if [ -z "$sid" ]; then
    echo "Error: session-hook: no session_id in hook input" >&2
    exit 1
fi

mkdir -p "$(dirname "$out")" || exit 1
printf '%s\n' "$sid" > "$out.tmp" && mv -f "$out.tmp" "$out"
