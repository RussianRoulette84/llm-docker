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
    # Save session ID for slot restore
    _save_slot_session
    exit 0
}

_save_slot_session() {
    if [ -z "$SLOT" ]; then
        return
    fi
    # If we resumed a known session, save that ID
    if [ -n "$SLOT_RESUME_ID" ]; then
        echo "$SLOT_RESUME_ID" > "/root/.claude/slot_${SLOT}.id"
        echo "[slot $SLOT] Saved resumed session: $SLOT_RESUME_ID"
        return
    fi
    # New session: find what's new since we started
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

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGQUIT

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


# Handle internet access restriction if INTERNET_ACCESS=false
if [ "${INTERNET_ACCESS:-true}" = "false" ]; then
    echo "Internet access disabled - blocking internet but allowing LAN access..."
    if [ -f /proc/self/ns/net ] && [ -e /proc/1/ns/net ]; then
        HOST_NS=$(readlink /proc/1/ns/net 2>/dev/null || echo "")
        SELF_NS=$(readlink /proc/self/ns/net 2>/dev/null || echo "")
        if [ "$HOST_NS" = "$SELF_NS" ] && [ -n "$HOST_NS" ]; then
            echo "Warning: Running in host network mode. Internet blocking will affect the host system."
            echo "For container-only blocking, use bridge network mode in docker-compose.yml"
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

# Determine which tool to run (default to opencode for backward compatibility)
TOOL=${TOOL:-opencode}

if [ "$TOOL" = "opencode" ]; then
    if [ -f /tmp/opencode.config.jsonc ]; then
        echo "Applying OpenCode configuration..."
        mkdir -p /root/.config/opencode
        cp /tmp/opencode.config.jsonc /root/.config/opencode/config.json
        echo "Configuration applied to /root/.config/opencode/config.json"
    fi
    if [ $# -gt 0 ]; then
        echo "Starting OpenCode with arguments: $@"
    else
        echo "Starting OpenCode..."
    fi
    # Run in background to capture PID for signal handling
    opencode "$@" &
    PID=$!
    wait $PID
    exit $?

elif [ "$TOOL" = "claude" ]; then
    if [ -d "/root_claude" ] && [ ! -L "/root_claude" ]; then
        if [ -d "/root" ] && [ ! -L "/root" ] && [ "$(ls -A /root 2>/dev/null)" ]; then
            echo "Warning: /root contains data. Moving to /root_backup..."
            mv /root /root_backup 2>/dev/null || true
        fi
        if [ ! -e "/root" ]; then
            ln -sf /root_claude /root
            echo "Linked /root_claude to /root for Claude Code"
        fi
    fi

    mkdir -p /root/.config/claude 2>/dev/null || true
    mkdir -p /root/.claude 2>/dev/null || true

    VERBOSE=${VERBOSE:-false}
    if [ "${NODE_ENV:-production}" = "development" ]; then
        VERBOSE=true
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

        cat > /root/.claude/settings.json <<EOF
{
  "hasCompletedOnboarding": true,
  "hasTrustDialogAccepted": true,
  "hasCompletedProjectOnboarding": true
}
EOF

        cat > /root/.claude.json <<EOF
{
  "hasCompletedOnboarding": true,
  "hasTrustDialogAccepted": true,
  "hasCompletedProjectOnboarding": true
}
EOF

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

    # Run in background to capture PID for signal handling
    claude "$@" &
    PID=$!
    wait $PID
    CLAUDE_EXIT=$?

    _save_slot_session
    exit $CLAUDE_EXIT

else
    echo "Error: Unknown TOOL value: $TOOL. Valid values are 'opencode' or 'claude'."
    exit 1
fi