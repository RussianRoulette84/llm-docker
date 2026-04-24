#!/bin/bash

# --- Signal handling for graceful shutdown ---
# This ensures the container stops properly when Docker sends SIGTERM/SIGINT
# instead of being force-killed (exit code 137)
PID=""  # Will hold the main process PID

cleanup() {
    echo "Received shutdown signal, stopping gracefully..."
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        # Forward signal to the child process
        kill -TERM "$PID" 2>/dev/null || true
        # Wait up to 10 seconds for graceful shutdown
        local timeout=10
        while [ $timeout -gt 0 ] && kill -0 "$PID" 2>/dev/null; do
            sleep 1
            ((timeout--))
        done
        # Force kill if still running
        if kill -0 "$PID" 2>/dev/null; then
            echo "Process didn't stop gracefully, forcing shutdown..."
            kill -KILL "$PID" 2>/dev/null || true
        fi
    fi
    # Save session ID for slot restore (dispatch by tool).
    case "${TOOL:-}" in
        claude)   _save_claude_slot_session ;;
        opencode) _save_opencode_slot_session ;;
    esac
    exit 0
}

_save_claude_slot_session() {
    if [ -z "$SLOT" ]; then
        return
    fi
    if [ -n "$SLOT_RESUME_ID" ]; then
        echo "$SLOT_RESUME_ID" > "/root/.claude/slot_${SLOT}.id"
        echo "[slot $SLOT] Saved resumed session: $SLOT_RESUME_ID"
        return
    fi
    if [ -n "$_SLOT_SNAPSHOT" ]; then
        local WORK_DIR=$(pwd)
        local SESSION_PROJECT_DIR="/root/.claude/projects/$(echo "$WORK_DIR" | sed 's|/|-|g')"
        if [ -d "$SESSION_PROJECT_DIR" ]; then
            local CURRENT=$(ls "$SESSION_PROJECT_DIR"/*.jsonl 2>/dev/null | sort)
            local NEW_FILE=$(comm -23 <(echo "$CURRENT") <(echo "$_SLOT_SNAPSHOT") | tail -1)
            if [ -n "$NEW_FILE" ]; then
                local SID=$(basename "$NEW_FILE" .jsonl)
                echo "$SID" > "/root/.claude/slot_${SLOT}.id"
                echo "[slot $SLOT] Saved new session: $SID"
                return
            fi
        fi
    fi
    echo "[slot $SLOT] Could not determine session ID"
}

# OpenCode sessions live in a SQLite DB. Find the newest session created in
# THIS container's workdir since launch and save its ID to the slot file.
_save_opencode_slot_session() {
    if [ -z "$SLOT" ]; then
        return
    fi
    local slot_file="/root/.local/share/opencode/slot_${SLOT}.id"
    if [ -n "$SLOT_RESUME_ID" ]; then
        echo "$SLOT_RESUME_ID" > "$slot_file"
        echo "[slot $SLOT] Saved resumed session: $SLOT_RESUME_ID"
        return
    fi
    local db="${_OCD_DB:-/root/.local/share/opencode/opencode.db}"
    [ -f "$db" ] || { echo "[slot $SLOT] OpenCode DB not found — skipping save"; return; }
    local wd; wd="$(pwd)"
    local wd_esc="${wd//\'/\'\'}"
    local start="${_OCD_START_EPOCH:-0}"
    local sid
    sid="$(sqlite3 "$db" \
        "SELECT id FROM session WHERE directory = '$wd_esc' AND time_created > $start ORDER BY time_created DESC LIMIT 1" \
        2>/dev/null)"
    if [ -n "$sid" ]; then
        echo "$sid" > "$slot_file"
        echo "[slot $SLOT] Saved new session: $sid"
    else
        echo "[slot $SLOT] Could not determine session ID"
    fi
}

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGQUIT

# When the tool exits, either leave the container (default) or drop the user
# into a bash shell inside it based on EXIT_TO_DOCKER. Typing 'exit' in that
# bash shell then ends the container (bash was exec'd in place of the
# entrypoint, so it's PID 1 — its exit ends the container).
_exit_or_drop_to_shell() {
    local tool="$1" exit_code="$2"
    if [ "${EXIT_TO_DOCKER:-false}" = "true" ]; then
        printf "\n%s exited (code %s). Dropped to container shell — type 'exit' to leave the container.\n\n" "$tool" "$exit_code"
        # Prefer zsh (login shell so ~/.zprofile sources) — fall back to bash.
        if command -v zsh >/dev/null 2>&1; then
            exec zsh -l
        fi
        exec bash
    fi
    exit "$exit_code"
}

# _launch_tmux_team TOOL [ARGS...] — spin up a 4-pane tmux session where
# every pane runs the same tool. Layout: left main pane (60% width) + right
# column split into 3 stacked panes (purple / orange / pink borders).
# Attaches in the foreground; returns tmux's exit code.
_launch_tmux_team() {
    local _tool="$1"; shift
    local _cmd="$_tool"
    local _a
    for _a in "$@"; do
        _cmd="$_cmd $(printf '%q' "$_a")"
    done
    # Last pane gets Haiku for claude (cheap/fast runner slot). Opencode
    # unchanged — only claude supports the --model haiku alias.
    local _cmd_last="$_cmd"
    if [ "$_tool" = "claude" ]; then
        _cmd_last="$_cmd --model haiku"
    fi

    local _sess="team"
    local _size="${TMUX_TEAM_SIZE:-0}"
    tmux new-session -d -s "$_sess" -x 240 -y 60 "$_cmd"
    local _p0 _p1 _p2 _p3
    _p0="$(tmux list-panes -t "$_sess" -F '#{pane_id}' | head -1)"

    # Color priority: first pane stays the terminal default. Remaining panes
    # follow the user's preference order: purple → blue → (orange reserved for
    # the haiku pane, always last).
    case "$_size" in
        2)
            # side-by-side
            _p1="$(tmux split-window -h -p 50 -t "$_p0" -P -F '#{pane_id}' "$_cmd_last")"
            tmux select-pane -t "$_p0" -T "@agent-1"
            tmux select-pane -t "$_p1" -T "@agent-2-haiku" -P 'fg=colour208'  # orange
            ;;
        3)
            # 1 main left + 2 stacked right
            _p1="$(tmux split-window -h -p 40 -t "$_p0" -P -F '#{pane_id}' "$_cmd")"
            _p2="$(tmux split-window -v -p 50 -t "$_p1" -P -F '#{pane_id}' "$_cmd_last")"
            tmux select-pane -t "$_p0" -T "@lead"
            tmux select-pane -t "$_p1" -T "@agent-1"       -P 'fg=colour141'  # purple
            tmux select-pane -t "$_p2" -T "@agent-2-haiku" -P 'fg=colour208'  # orange
            ;;
        4)
            # 2x2 grid
            _p1="$(tmux split-window -h -p 50 -t "$_p0" -P -F '#{pane_id}' "$_cmd")"
            _p2="$(tmux split-window -v -p 50 -t "$_p0" -P -F '#{pane_id}' "$_cmd")"
            _p3="$(tmux split-window -v -p 50 -t "$_p1" -P -F '#{pane_id}' "$_cmd_last")"
            tmux select-pane -t "$_p0" -T "@agent-1"
            tmux select-pane -t "$_p1" -T "@agent-2"       -P 'fg=colour141'  # purple
            tmux select-pane -t "$_p2" -T "@agent-3"       -P 'fg=colour81'   # blue
            tmux select-pane -t "$_p3" -T "@agent-4-haiku" -P 'fg=colour208'  # orange
            ;;
        *)
            # default: 1 main left + 3 stacked right
            _p1="$(tmux split-window -h -p 40 -t "$_p0" -P -F '#{pane_id}' "$_cmd")"
            _p2="$(tmux split-window -v -p 66 -t "$_p1" -P -F '#{pane_id}' "$_cmd")"
            _p3="$(tmux split-window -v -p 50 -t "$_p2" -P -F '#{pane_id}' "$_cmd_last")"
            tmux select-pane -t "$_p0" -T "@lead"
            tmux select-pane -t "$_p1" -T "@agent-1"       -P 'fg=colour141'  # purple
            tmux select-pane -t "$_p2" -T "@agent-2"       -P 'fg=colour81'   # blue
            tmux select-pane -t "$_p3" -T "@agent-3-haiku" -P 'fg=colour208'  # orange
            ;;
    esac

    tmux set -t "$_sess" pane-border-status top
    tmux set -t "$_sess" pane-border-format " #{pane_title} "
    tmux set -t "$_sess" pane-border-lines heavy

    # ── Dracula-ish powerline status bar (scoped to this team session only) ──
    # Matches the pane-title palette: purple primary, orange reserved for Haiku.
    # Powerline chevron () needs a nerd font — same one p10k already requires.
    local _PUR=colour141 _ORG=colour208 _PNK=colour213
    local _BG=colour236  _FG=colour250  _DIM=colour244
    tmux set -t "$_sess" status on
    tmux set -t "$_sess" status-interval 5
    tmux set -t "$_sess" status-style           "bg=${_BG},fg=${_FG}"
    tmux set -t "$_sess" status-left-length     40
    tmux set -t "$_sess" status-right-length    60
    tmux set -t "$_sess" status-left            "#[bg=${_PUR},fg=${_BG},bold] ⚡ #S #[bg=${_BG},fg=${_PUR}] "
    tmux set -t "$_sess" status-right           "#[fg=${_ORG}]#[bg=${_ORG},fg=${_BG},bold]  haiku #[bg=${_BG},fg=${_ORG}] #[fg=${_PUR}]#[bg=${_PUR},fg=${_BG},bold] %H:%M "
    tmux set -t "$_sess" window-status-current-format "#[fg=${_PNK},bold]#I:#W"
    tmux set -t "$_sess" window-status-format         "#[fg=${_DIM}]#I:#W"
    tmux set -t "$_sess" pane-active-border-style "fg=${_PNK}"
    tmux set -t "$_sess" pane-border-style        "fg=${_DIM}"

    tmux select-pane -t "$_p0"
    tmux attach -t "$_sess"
}

# Strip iTerm2-specific environment variables to prevent interference
unset ITERM2_SHELL_INTEGRATION_INSTALLED
unset ITERM2_SHELL_INTEGRATION_ENABLED
unset ITERM2_SHELL_INTEGRATION_PREVIOUS_PROMPT
unset ITERM2_PREV_PS1
unset ITERM2_SHELL_PREV_PS2
# Ensure proper terminal setup for mouse reporting and scrolling
# Set TERMINFO path for ncurses-term package
export TERMINFO=/usr/share/terminfo
export TERMINFO_DIRS=/usr/share/terminfo
# Set TERM if not already set (fallback to xterm-256color)
export TERM=${TERM:-xterm-256color}
# Ensure terminal size is set
if [ -z "$COLUMNS" ] || [ -z "$LINES" ]; then
    if command -v stty > /dev/null 2>&1; then
        TERM_SIZE=$(stty size 2>/dev/null || echo "24 80")
        LINES=${LINES:-$(echo $TERM_SIZE | cut -d' ' -f1)}
        COLUMNS=${COLUMNS:-$(echo $TERM_SIZE | cut -d' ' -f2)}
        export LINES COLUMNS
    fi
fi


# Banner ASCII bind-mounted from src/ascii/llm-docker.txt (single source of truth).
# Piped through colorize.sh for a blue → light-blue → white vertical gradient.
# Falls back to plain cat if zsh/colorize are missing.
if [ -f /opt/llm-docker/ascii.txt ]; then
    if [ -f /opt/llm-docker/colorize.sh ] && command -v zsh >/dev/null 2>&1; then
        zsh /opt/llm-docker/colorize.sh < /opt/llm-docker/ascii.txt
    else
        cat /opt/llm-docker/ascii.txt
    fi
fi
_llm_version=$(grep -oE 'Version-v[0-9.]+' /opt/llm-docker/README.md 2>/dev/null | head -1 | sed 's/Version-//')
_llm_version="${_llm_version:-unknown}"
_llm_pad=$(( (50 - ${#_llm_version}) / 2 ))
# xterm-256 141 — slightly darker purple than the subtitle (177), matches
# the host-side setup.sh banner styling.
printf "%${_llm_pad}s\033[38;5;141m%s\033[0m\n" "" "$_llm_version"
unset _llm_version _llm_pad

# Handle internet access restriction if INTERNET_ACCESS=false
if [ "${INTERNET_ACCESS:-true}" = "false" ]; then
    echo "Internet access disabled - blocking internet but allowing LAN access..."
    if [ -f /proc/self/ns/net ] && [ -e /proc/1/ns/net ]; then
        HOST_NS=$(readlink /proc/1/ns/net 2>/dev/null || echo "")
        SELF_NS=$(readlink /proc/self/ns/net 2>/dev/null || echo "")
        if [ "$HOST_NS" = "$SELF_NS" ] && [ -n "$HOST_NS" ]; then
            echo "Warning: Running in host network mode. Internet blocking will affect the host system."
            echo "For container-only blocking, set INTERNET_ACCESS=false in llm-docker.conf (cld/ocd will switch the container to bridge mode)."
        fi
    fi
    if command -v iptables > /dev/null 2>&1; then
        iptables -F OUTPUT 2>/dev/null || true
        iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -d 169.254.0.0/16 -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -j DROP 2>/dev/null || true
        echo "Internet access blocked. LAN access (10.x.x.x, 172.16-31.x.x, 192.168.x.x) allowed."
    else
        echo "Warning: iptables not available. Cannot block internet access."
        echo "Note: Internet blocking requires bridge network mode (not host mode) to work properly."
    fi
fi

# Start sshd if enabled in llm-docker.conf. Runs in background; the tool
# (claude/opencode) still owns the foreground TTY.
if [ "${LLM_DOCKER_SSH_ENABLED:-false}" = "true" ] && [ -x /setup-ssh.sh ]; then
    /setup-ssh.sh || echo "[SSH] setup-ssh.sh failed — container continues without ssh"
fi

# Auto-update claude-code and opencode on launch when UPDATE_ON_START=true.
# Skipped when internet is blocked (npm registry unreachable).
if [ "${UPDATE_ON_START:-false}" = "true" ] && [ "${INTERNET_ACCESS:-true}" = "true" ]; then
    echo "[update] Checking for claude-code and opencode updates..."
    _upd_log=$(mktemp)
    if npm install -g --silent @anthropic-ai/claude-code@latest opencode-ai@latest >"$_upd_log" 2>&1 \
         && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs >>"$_upd_log" 2>&1; then
        sed 's/^/[update] /' "$_upd_log"
        echo "[update] Done."
    else
        sed 's/^/[update] /' "$_upd_log"
        echo "[update] Update failed — continuing with installed versions."
    fi
fi

# Determine which tool to run (default to opencode for backward compatibility)
TOOL=${TOOL:-opencode}

if [ "$TOOL" = "opencode" ]; then
    if [ -f /opt/llm-docker/templates/opencode.config.jsonc ]; then
        echo "Applying OpenCode configuration..."
        mkdir -p /root/.config/opencode
        cp /opt/llm-docker/templates/opencode.config.jsonc /root/.config/opencode/config.json
        echo "Configuration applied to /root/.config/opencode/config.json"
    fi

    # Slot save baseline: use the DB's current MAX(time_created) so the unit
    # (ms/sec) doesn't matter — anything newer is a session started here.
    _OCD_DB=/root/.local/share/opencode/opencode.db
    _OCD_START_EPOCH=0
    if [ -f "$_OCD_DB" ] && [ -n "$SLOT" ]; then
        _OCD_START_EPOCH="$(sqlite3 "$_OCD_DB" \
            "SELECT COALESCE(MAX(time_created), 0) FROM session" 2>/dev/null || echo 0)"
    fi

    # Dispatch: explicit session ID wins, then --continue, then fresh.
    OPENCODE_ARGS=()
    if [ -n "${SLOT_RESUME_ID:-}" ]; then
        OPENCODE_ARGS=(-s "$SLOT_RESUME_ID")
        echo "[slot ${SLOT:-?}] Resuming session $SLOT_RESUME_ID"
    elif [ "${CONTINUE_SESSION:-false}" = "true" ]; then
        OPENCODE_ARGS=(-c)
    elif [ -n "${OPENCODE_INIT_PROMPT:-}" ]; then
        OPENCODE_ARGS=(--prompt "$OPENCODE_INIT_PROMPT")
    fi

    if [ $# -gt 0 ] || [ ${#OPENCODE_ARGS[@]} -gt 0 ]; then
        echo "Starting OpenCode with arguments: ${OPENCODE_ARGS[*]} $*"
    else
        echo "Starting OpenCode..."
    fi
    # Run opencode in the FOREGROUND. Backgrounding with `&` + `wait` prevents
    # opencode's TUI from owning the TTY — arrow keys leak through as literal
    # `^[[A/B/Z` instead of being intercepted as navigation. Signal handling
    # for graceful shutdown still works because bash's SIGTERM/SIGINT trap
    # runs on the next command-boundary.
    if [ "${TMUX_TEAM:-false}" = "true" ] && command -v tmux >/dev/null 2>&1; then
        _launch_tmux_team opencode "${OPENCODE_ARGS[@]}" "$@"
    elif [ "${TMUX_CODEMAN:-false}" = "true" ]; then
        if ! command -v codeman >/dev/null 2>&1; then
            echo "[codeman] binary missing — image may have been built before codeman was baked in." >&2
            echo "[codeman] rebuild: docker rmi llm-docker:latest && ocd" >&2
        else
            echo "[codeman] starting web UI on http://localhost:3000 …"
            codeman web "${OPENCODE_ARGS[@]}" "$@"
        fi
    elif [ "${USE_TMUX:-false}" = "true" ] && command -v tmux >/dev/null 2>&1; then
        # tmux wraps the launch so SSH disconnects / accidental window
        # closes don't kill the tool — reattach with `tmux a -t opencode`.
        _tmux_cmd="opencode"
        for _arg in "${OPENCODE_ARGS[@]}" "$@"; do
            _tmux_cmd="$_tmux_cmd $(printf '%q' "$_arg")"
        done
        tmux new-session -A -s opencode "$_tmux_cmd"
    else
        opencode "${OPENCODE_ARGS[@]}" "$@"
    fi
    _rc=$?

    _save_opencode_slot_session
    _exit_or_drop_to_shell "OpenCode" "$_rc"

elif [ "$TOOL" = "claude" ]; then
    mkdir -p /root/.config/claude 2>/dev/null || true
    mkdir -p /root/.claude 2>/dev/null || true
    # DOCKER_DIR is the mount-parent; docker run -w creates per-mount subdirs.
    mkdir -p "${DOCKER_DIR:-/root}" 2>/dev/null || true

    VERBOSE=${VERBOSE:-false}
    if [ "${NODE_ENV:-production}" = "development" ]; then
        VERBOSE=true
    fi

    # Re-seed Claude Code permissions from the repo-bundled template, but
    # ONLY on a fresh session. Resuming (-c or --resume <uuid>) preserves
    # whatever the user accumulated ("allow this once" grants etc.) — cld
    # sets NEW_CLAUDE_SESSION=false in that case.
    if [ "${NEW_CLAUDE_SESSION:-false}" = "true" ] \
       && [ -f /opt/llm-docker/templates/claude-settings.json ]; then
        cp /opt/llm-docker/templates/claude-settings.json /root/.claude/settings.local.json
        if [ "$VERBOSE" = "true" ]; then
            echo "[claude] fresh session — re-applied default permissions" \
                 "from /opt/llm-docker/templates/claude-settings.json"
        fi
    fi

    # --danger / --dg on host → bypass permissions entirely. Overwrites
    # settings.local.json with the bypassPermissions stanza AND prepends
    # --dangerously-skip-permissions to claude's argv below.
    if [ "${DANGER_MODE:-false}" = "true" ]; then
        cat > /root/.claude/settings.local.json <<'EOF'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
EOF
        set -- --dangerously-skip-permissions "$@"
        if [ "$VERBOSE" = "true" ]; then
            echo "[claude] DANGER_MODE=true — --dangerously-skip-permissions + bypassPermissions settings applied"
        fi
    fi

    if [ -n "$ANTHROPIC_API_KEY" ]; then
        export ANTHROPIC_API_KEY

        if [ "$VERBOSE" = "true" ]; then
            echo "ANTHROPIC_API_KEY is set (length: ${#ANTHROPIC_API_KEY} chars)"
            echo "Configuring Claude Code to use API key authentication..."
        fi

        rm -f /root/.config/claude/token.json 2>/dev/null || true
        rm -f /root/.config/claude/auth.json 2>/dev/null || true
        rm -rf /root/.config/claude/oauth 2>/dev/null || true

        # Seed onboarding stubs only if the file is absent/empty — do NOT
        # clobber existing user state (trusted projects, MCP config, etc.)
        # which now persists via the narrow bind mount.
        if [ ! -s /root/.claude/settings.json ]; then
            cat > /root/.claude/settings.json <<EOF
{
  "hasCompletedOnboarding": true,
  "hasTrustDialogAccepted": true,
  "hasCompletedProjectOnboarding": true
}
EOF
        fi

        if [ ! -s /root/.claude.json ]; then
            cat > /root/.claude.json <<EOF
{
  "hasCompletedOnboarding": true,
  "hasTrustDialogAccepted": true,
  "hasCompletedProjectOnboarding": true
}
EOF
        fi

        if [ "$VERBOSE" = "true" ]; then
            echo "Claude Code configured to use API key authentication"
        fi
    fi

    if [ "$VERBOSE" = "true" ]; then
        if [ $# -gt 0 ]; then
            echo "Starting Claude Code with arguments: $@"
        else
            echo "Starting Claude Code..."
        fi
    fi
    # Snapshot existing sessions before Claude starts (for new session detection per slot)
    _SLOT_SNAPSHOT=""
    if [ -n "$SLOT" ] && [ -z "$SLOT_RESUME_ID" ]; then
        WORK_DIR=$(pwd)
        SESSION_PROJECT_DIR="/root/.claude/projects/$(echo "$WORK_DIR" | sed 's|/|-|g')"
        mkdir -p "$SESSION_PROJECT_DIR" 2>/dev/null || true
        _SLOT_SNAPSHOT=$(ls "$SESSION_PROJECT_DIR"/*.jsonl 2>/dev/null | sort)
    fi

    # Run in background to capture PID for signal handling.
    # tmux path intentionally skips the & + wait pattern: tmux must own the
    # TTY to attach. Trade-off: SIGTERM during tmux mode defers cleanup until
    # the tmux session exits.
    if [ "${TMUX_TEAM:-false}" = "true" ] && command -v tmux >/dev/null 2>&1; then
        _launch_tmux_team claude "$@"
        CLAUDE_EXIT=$?
    elif [ "${TMUX_RECON:-false}" = "true" ]; then
        if ! command -v recon >/dev/null 2>&1; then
            echo "[recon] binary missing — image may have been built before recon was baked in." >&2
            echo "[recon] rebuild: docker rmi llm-docker:latest && cld" >&2
            CLAUDE_EXIT=127
        elif ! command -v tmux >/dev/null 2>&1; then
            echo "[recon] tmux missing inside the container — recon needs it." >&2
            CLAUDE_EXIT=127
        else
            recon "$@"
            CLAUDE_EXIT=$?
        fi
    elif [ "${TMUX_CODEMAN:-false}" = "true" ]; then
        if ! command -v codeman >/dev/null 2>&1; then
            echo "[codeman] binary missing — image may have been built before codeman was baked in." >&2
            echo "[codeman] rebuild: docker rmi llm-docker:latest && cld" >&2
            CLAUDE_EXIT=127
        else
            echo "[codeman] starting web UI on http://localhost:3000 …"
            codeman web "$@"
            CLAUDE_EXIT=$?
        fi
    elif [ "${TMUX_CLAUDE:-false}" = "true" ]; then
        if ! command -v claude-tmux >/dev/null 2>&1; then
            echo "[claude-tmux] binary missing — rebuild: docker rmi llm-docker:latest && cld" >&2
            CLAUDE_EXIT=127
        elif ! command -v tmux >/dev/null 2>&1; then
            echo "[claude-tmux] tmux missing inside the container — claude-tmux needs it." >&2
            CLAUDE_EXIT=127
        else
            _tmux_cmd="claude"
            for _arg in "$@"; do
                _tmux_cmd="$_tmux_cmd $(printf '%q' "$_arg")"
            done
            tmux new-session -Ad -s claude "$_tmux_cmd"
            tmux bind-key C-c display-popup -E -w 80 -h 30 claude-tmux
            echo "[claude-tmux] tmux session 'claude' ready — press Ctrl+b Ctrl+c for the popup"
            tmux attach -t claude
            CLAUDE_EXIT=$?
        fi
    elif [ "${USE_TMUX:-false}" = "true" ] && command -v tmux >/dev/null 2>&1; then
        _tmux_cmd="claude"
        for _arg in "$@"; do
            _tmux_cmd="$_tmux_cmd $(printf '%q' "$_arg")"
        done
        tmux new-session -A -s claude "$_tmux_cmd"
        CLAUDE_EXIT=$?
    else
        claude "$@" &
        PID=$!
        wait $PID
        CLAUDE_EXIT=$?
    fi

    _save_claude_slot_session
    _exit_or_drop_to_shell "Claude" "$CLAUDE_EXIT"

else
    echo "Error: Unknown TOOL value: $TOOL. Valid values are 'opencode' or 'claude'."
    exit 1
fi