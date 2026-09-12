#!/bin/bash

# --- Signal handling for graceful shutdown ---
# This ensures the container stops properly when Docker sends SIGTERM/SIGINT
# instead of being force-killed (exit code 137)
PID=""  # Will hold the main process PID

# Helper functions live in entrypoint-lib.sh (same delivery as this file:
# baked into the image + bind-mounted by cld/ocd). Source it fail-loud.
_ENTRYPOINT_LIB="/usr/local/bin/entrypoint-lib.sh"
if [ ! -f "$_ENTRYPOINT_LIB" ]; then
    echo "docker-entrypoint: missing $_ENTRYPOINT_LIB — broken image?" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_ENTRYPOINT_LIB"

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
if [ "${LLM_D0CKER_SHH_EN4BLED:-false}" = "true" ] && [ -x /setup-ssh.sh ]; then
    /setup-ssh.sh || echo "[SSH] setup-ssh.sh failed — container continues without ssh"
fi

# Outbound SSH — in-container ssh-agent pattern.
#
# Keys arrive via env-gorilla vault (or plain .env) as base64-encoded env
# vars. They are loaded into an in-container ssh-agent via `ssh-add -`
# (stdin) and NEVER written to disk. The only file that touches disk is
# /root/.ssh/config — plaintext hostnames + users, no secret material.
# Trap on EXIT kills the agent so keys leave memory when the container stops.
#
# The ssh_config comes from one of two sources, in priority order:
#   1. $S3C_ATTACHMENT_DIR/config — file dropped by env-gorilla at unlock time
#      (vault mode with attachment support)
#   2. $LLM_D0CKER_SHH_CFG_B64    — base64-encoded config in the env var
#      (.env fallback mode for public users without s3c-gorilla)
#
# Every login shell inherits SSH_AUTH_SOCK via /etc/profile.d/ssh-agent.sh.
if [ -n "${LLMD0CKER_SHH_3D25519_PVYT_B64:-}${PS4_SHH_3D25519_PVYT_B64:-}${LLM_D0CKER_SHH_CFG_B64:-}" ] \
   || [ -f "${S3C_ATTACHMENT_DIR:-}/config" ]; then
    eval "$(ssh-agent -s)" >/dev/null
    export SSH_AUTH_SOCK SSH_AGENT_PID
    printf 'export SSH_AUTH_SOCK=%s\nexport SSH_AGENT_PID=%s\n' \
        "$SSH_AUTH_SOCK" "$SSH_AGENT_PID" > /etc/profile.d/ssh-agent.sh
    chmod 644 /etc/profile.d/ssh-agent.sh

    _load_key() {
        local var="$1" label="$2"
        local val="${!var}"
        [ -n "$val" ] || return 0
        if printf '%s' "$val" | base64 -d 2>/dev/null | ssh-add - >/dev/null 2>&1; then
            echo "[ssh-agent] loaded $label"
        else
            echo "[ssh-agent] FAILED to load $label — check $var in vault/.env"
        fi
    }
    _load_key LLMD0CKER_SHH_3D25519_PVYT_B64 llmdocker
    _load_key PS4_SHH_3D25519_PVYT_B64       ps4

    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    if [ -f "${S3C_ATTACHMENT_DIR:-}/config" ]; then
        cp "$S3C_ATTACHMENT_DIR/config" /root/.ssh/config
        chmod 600 /root/.ssh/config
        echo "[ssh-agent] loaded /root/.ssh/config from vault attachment ($S3C_ATTACHMENT_DIR/config)"
    elif [ -n "${LLM_D0CKER_SHH_CFG_B64:-}" ]; then
        printf '%s' "$LLM_D0CKER_SHH_CFG_B64" | base64 -d > /root/.ssh/config
        chmod 600 /root/.ssh/config
        echo "[ssh-agent] loaded /root/.ssh/config from .env base64"
    else
        echo "[ssh-agent] WARNING: no ~/.ssh/config found — vault attachment missing and LLM_D0CKER_SHH_CFG_B64 empty."
        echo "[ssh-agent]   → outbound ssh will fall back to ssh's built-in defaults."
        echo "[ssh-agent]   → attach 'config' to KeePassXC entry SSH/llm-docker-ssh-config, OR set LLM_D0CKER_SHH_CFG_B64 in .env."
    fi

    trap 'ssh-agent -k >/dev/null 2>&1' EXIT
fi

# Auto-update the LAUNCHED tool's npm package when UPDATE_ON_START=true:
# cld (TOOL=claude) updates claude-code only, ocd (TOOL=opencode) updates
# opencode only. Skipped when internet is blocked (npm registry unreachable).
# Throttled to once per CHECK_UPDATE_EVERY_X_DAYS days (src/llm-docker.conf,
# default 7) via a per-tool marker in a host-persisted bind mount — timers
# survive container restarts and the two tools never reset each other.
# Override with UPDATE_FORCE=1 when you want to force a check immediately.
if [ "${UPDATE_ON_START:-false}" = "true" ] && [ "${INTERNET_ACCESS:-true}" = "true" ]; then
    case "${TOOL:-opencode}" in
        claude)
            _upd_pkg="@anthropic-ai/claude-code@latest"
            _upd_marker=/root/.claude/.last_update_check
            ;;
        opencode)
            _upd_pkg="opencode-ai@latest"
            _upd_marker=/root/.config/opencode/.last_update_check
            ;;
        *)
            _upd_pkg=""
            _upd_marker=""
            ;;
    esac
    if [ -n "$_upd_pkg" ]; then
        _upd_interval=$(( ${CHECK_UPDATE_EVERY_X_DAYS:-7} * 86400 ))
        _upd_due=true
        if [ "${UPDATE_FORCE:-false}" != "true" ] && [ -f "$_upd_marker" ]; then
            _upd_age=$(( $(date +%s) - $(stat -c %Y "$_upd_marker" 2>/dev/null || echo 0) ))
            if [ "$_upd_age" -lt "$_upd_interval" ]; then
                _upd_due=false
                echo "[update] Last ${TOOL:-opencode} check $((_upd_age / 86400))d ago — skipping (UPDATE_FORCE=1 to override)."
            fi
        fi
        if [ "$_upd_due" = true ]; then
            echo "[update] Checking for ${TOOL:-opencode} updates..."
            _upd_log=$(mktemp)
            _upd_ok=true
            npm install -g --silent "$_upd_pkg" >"$_upd_log" 2>&1 || _upd_ok=false
            if [ "$_upd_ok" = true ] && [ "${TOOL:-opencode}" = "claude" ]; then
                node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs >>"$_upd_log" 2>&1 || _upd_ok=false
            fi
            if [ "$_upd_ok" = true ]; then
                sed 's/^/[update] /' "$_upd_log"
                echo "[update] Done."
                touch "$_upd_marker" 2>/dev/null || true
            else
                sed 's/^/[update] /' "$_upd_log"
                echo "[update] Update failed — continuing with installed version."
            fi
            unset _upd_log _upd_ok
        fi
        unset _upd_interval _upd_due _upd_age
    fi
    unset _upd_pkg _upd_marker
fi

# Source /root/.zprofile so PATH (composer/vendor/bin, go/bin, GOPATH/bin,
# anything else the user has wired in) is set for the launched tool AND
# for every `bash -c "..."` spawned by it (Claude Code's Bash tool, agent
# shell-outs, scripted invocations). The entrypoint runs as a plain bash
# script — not a login shell — so /root/.zprofile is NOT auto-sourced.
# This catches it once at process start and lets every child inherit.
# if [ -f /root/.zprofile ]; then
#     # shellcheck disable=SC1091
#     . /root/.zprofile 2>/dev/null || true
# fi

# Determine which tool to run (default to opencode for backward compatibility)
TOOL=${TOOL:-opencode}

if [ "$TOOL" = "opencode" ]; then
    # DB maintenance mode (ocd --dbrestore / --dbbackup): run the repair
    # tool interactively instead of opencode. No bootstrap, no replicator —
    # a restore must not race live writers.
    if [ -n "${DB_MAINTAIN:-}" ]; then
        _maint=/usr/local/bin/ocd-db-maintain.sh
        if [ ! -f "$_maint" ]; then
            echo "[opencode-db] ERROR: maintenance script missing at $_maint" >&2
            exit 1
        fi
        _maint_args=()
        [ "$DB_MAINTAIN" = "backup" ] && _maint_args=(--backup)
        echo "[opencode-db] maintenance mode: ${DB_MAINTAIN} (opencode not started)"
        bash "$_maint" "${_maint_args[@]}"
        _rc=$?
        _exit_or_drop_to_shell "OpenCode-db" "$_rc"
    fi

    # SQLite safety: live data dir is a Docker volume (WAL-safe ext4);
    # opencode-db.sh seeds it from the macOS mirror on first boot and
    # mirrors changes back after every write burst. See the script header.
    if [ -f /usr/local/bin/opencode-db.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/bin/opencode-db.sh
        _oc_db_bootstrap
    else
        echo "[opencode-db] ERROR: opencode-db.sh missing — DB mirror disabled"
    fi

    # Seed OpenCode config from the repo-bundled template ONLY on first
    # launch (when the host-persisted config.json is absent/empty).
    # ~/.llm-docker/opencode/.config/opencode/ is bind-mounted and is the
    # user's source of truth — clobbering it every launch threw away model
    # changes made on the host (same rule Claude's settings.local.json uses).
    mkdir -p /root/.config/opencode
    if [ ! -s /root/.config/opencode/config.json ] \
       && [ -f /opt/llm-docker/templates/opencode.config.jsonc ]; then
        cp /opt/llm-docker/templates/opencode.config.jsonc /root/.config/opencode/config.json
        echo "[opencode] first launch — seeded config.json from template"
    fi

    # Slot save baseline: use the DB's current MAX(time_created) so the unit
    # (ms/sec) doesn't matter — anything newer is a session started here.
    _OCD_DB=/root/.local/share/opencode/opencode.db
    _OCD_START_EPOCH=0
    if [ -f "$_OCD_DB" ] && [ -n "$SLOT" ]; then
        _OCD_START_EPOCH="$(sqlite3 "$_OCD_DB" \
            "SELECT COALESCE(MAX(time_created), 0) FROM session" 2>/dev/null || echo 0)"
    fi

    # Degrade-to-fresh guards: a remembered session that no longer exists
    # (wiped volume, other machine) or `-c` with zero sessions in this
    # project must start FRESH, not exit with an error.
    if [ -n "${SLOT_RESUME_ID:-}" ] && [ -f "$_OCD_DB" ]; then
        if ! sqlite3 "$_OCD_DB" "SELECT 1 FROM session WHERE id='${SLOT_RESUME_ID}'" 2>/dev/null | grep -q 1; then
            echo "[opencode] remembered session $SLOT_RESUME_ID not found — starting fresh"
            SLOT_RESUME_ID=""
        fi
    fi
    if [ -z "${SLOT_RESUME_ID:-}" ] && [ "${CONTINUE_SESSION:-false}" = "true" ] && [ -f "$_OCD_DB" ]; then
        _wd="$(pwd)"; _wd_esc="${_wd//\'/\'\'}"
        _have_sessions="$(sqlite3 "$_OCD_DB" \
            "SELECT COUNT(*) FROM session WHERE directory='$_wd_esc'" 2>/dev/null || echo 1)"
        if [ "${_have_sessions:-1}" = "0" ]; then
            echo "[opencode] no sessions in this project yet — starting fresh"
            CONTINUE_SESSION=false
        fi
        unset _wd _wd_esc _have_sessions
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
    # Plain launch runs opencode in the FOREGROUND — see the else-branch
    # comment. tmux/codeman paths wrap it in a server that owns the TTY, so
    # they are unaffected.
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
        # FOREGROUND on purpose — do NOT use the claude `&` + `wait` shape
        # here. A backgrounded opencode TUI loses raw-mode input handling:
        # arrow keys and mouse events leak to the shell as literal escape
        # garbage (iTerm2 shows junk chars while scrolling / typing %% at
        # the prompt). Ctrl+C still exits on ONE press in this shape:
        # SIGINT hits the foreground process group → opencode quits itself
        # (its "ctrl+c exit" binding) and restores the terminal → bash then
        # runs the deferred SIGINT trap (cleanup() → slot save + DB exit
        # sync) → container ends → you land back on the macOS prompt.
        opencode "${OPENCODE_ARGS[@]}" "$@"
    fi
    _rc=$?

    _save_opencode_slot_session
    type _oc_db_finish >/dev/null 2>&1 && _oc_db_finish
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

    # Seed Claude Code permissions from the repo-bundled template ONLY on
    # first launch (when settings.local.json is absent). Yaro's
    # ~/.llm-docker/claude/.claude/ is now a git-tracked source of truth
    # synced across his 2 macs — clobbering it every fresh session would
    # destroy his customizations.
    if [ ! -s /root/.claude/settings.local.json ] \
       && [ -f /opt/llm-docker/templates/claude-settings.json ]; then
        cp /opt/llm-docker/templates/claude-settings.json /root/.claude/settings.local.json
        if [ "$VERBOSE" = "true" ]; then
            echo "[claude] first launch — seeded settings.local.json from template"
        fi
    fi

    # --danger / --dg on host → bypass permissions entirely. The argv flag
    # below is what actually enables it; the settings.local.json entry is
    # belt-and-suspenders. Only seed the file if missing — do NOT clobber
    # the user's existing settings.
    if [ "${DANGER_MODE:-false}" = "true" ]; then
        if [ ! -s /root/.claude/settings.local.json ]; then
            cat > /root/.claude/settings.local.json <<'EOF'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
EOF
        fi
        set -- --dangerously-skip-permissions "$@"
        if [ "$VERBOSE" = "true" ]; then
            echo "[claude] DANGER_MODE=true — --dangerously-skip-permissions applied"
        fi
    fi

    if [ -n "$_4NTHR0P1C_H4NDLE" ]; then
        export _4NTHR0P1C_H4NDLE

        if [ "$VERBOSE" = "true" ]; then
            echo "_4NTHR0P1C_H4NDLE is set (length: ${#_4NTHR0P1C_H4NDLE} chars)"
            echo "Configuring Claude Code to use API key authentication..."
        fi

        # Intentional credential clear when switching to API-key auth. Use the
        # REAL rm (not the /usr/local/bin/rm guard) — these are specific config
        # files, deliberately removed, and the guard would otherwise trash them.
        /bin/rm -f /root/.config/claude/token.json 2>/dev/null || true
        /bin/rm -f /root/.config/claude/auth.json 2>/dev/null || true
        /bin/rm -rf /root/.config/claude/oauth 2>/dev/null || true

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
