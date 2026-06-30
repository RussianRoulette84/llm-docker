#!/bin/bash
# entrypoint-lib.sh — helper functions for docker-entrypoint.sh (graceful
# shutdown, slot-session save, tmux team layout). Split out to keep the
# entrypoint under the 500-line cap. Sourced by docker-entrypoint.sh at start;
# both are delivered the same way (baked via Dockerfile + bind-mounted by
# cld/ocd so edits take effect without a rebuild). Shares the entrypoint shell
# scope, so globals like $PID are visible when these run.

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
        # if command -v zsh >/dev/null 2>&1; then
        #     exec zsh -l
        # fi
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
