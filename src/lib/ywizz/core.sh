#!/bin/bash

# --- ywizz Core (Symbols & Helpers) ---

# Source theme from the same directory
source "$(dirname "${BASH_SOURCE[0]}")/theme.sh"

# TUI Symbols
TREE_TOP="┌ "
TREE_MID="│ "
TREE_BOT="└ "
TREE_BRANCH="├ "
TREE_CONNECTOR="${TREE_MID:0:1}"   # Single │ to chain wizard blocks
BULLET_FILLED="● "
BULLET_EMPTY="○ "
DIAMOND_FILLED="◆ "
DIAMOND_EMPTY="◇ "
# Spinning wheel for loading (cycle: ◐ ◑ ◒ ◓)
SPINNER_FRAMES=("◐" "◑" "◒" "◓")
SPINNER_COUNT=4

# Theme Accessors
get_accent() {
    echo "$accent_color"
}

# Strip dimmed "subtitle" tail from a prompt when rendering inactive/answered view.
# Convention: subtitles are typically appended using DIM (often via ${dim_color}) at the end of the prompt.
# We remove everything starting at the first DIM sequence, and also remove the trailing color escape
# that immediately precedes it (usually the accent color), plus the space before it.
ywizz_prompt_without_subtitle() {
    local s="$1"
    local esc=$'\033'

    [[ -z "$s" ]] && { echo ""; return 0; }

    # Only act if the prompt contains a DIM escape; otherwise return unchanged.
    if [[ "$s" == *"$DIM"* ]]; then
        local before_dim="${s%%$DIM*}"
        # If the DIM was introduced by an appended colored subtitle, the substring right before DIM
        # often ends with "... <space><ESC>...m" (the color code). Remove that tail too.
        if [[ "$before_dim" == *" ${esc}"* ]]; then
            before_dim="${before_dim% ${esc}*}"
        fi
        # Trim any remaining trailing whitespace.
        before_dim="${before_dim%"${before_dim##*[![:space:]]}"}"
        echo "$before_dim"
        return 0
    fi

    echo "$s"
}


style_item() {
    local acc=$(get_accent)
    printf "%b%s %s%b\n" "$acc" "$TREE_MID" "$1" "$RESET"
}
