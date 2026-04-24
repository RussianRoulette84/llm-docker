#!/bin/bash

# --- ywizz Header (Section Titles) ---

# $1=Title, $2=Subtitle (optional), $3=wizard (optional, "1" = chained with │, no blank line; active section = ◆)
header_tui() {
    local title="$1"
    local subtitle="$2"
    local wizard="${3:-0}"
    local acc=$(get_accent)

    if [ "$wizard" = "1" ]; then
        printf "%b%s%b%b%b\n" "$acc" "$DIAMOND_FILLED" "$acc" "$title" "$RESET"
        [ -n "$subtitle" ] && printf "%b%s %b%b%b\n" "$acc" "$TREE_MID" "$RESET" "$subtitle" "$RESET"
        return 0
    fi

    printf "%b%s%s%b%b%b\n" "$acc" "$TREE_TOP" "$DIAMOND_FILLED" "$acc" "$title" "$RESET"
    [ -n "$subtitle" ] && printf "%b%s %b%b%b\n" "$acc" "$TREE_MID" "$RESET" "$subtitle" "$RESET"
    return 0
}

# Clear a wizard section entirely (no ◇ replacement). Use when the step should not appear in the final tree.
# $1=number of lines the section used
header_tui_clear() {
    local lines="${1:-1}"
    [ "$lines" -lt 1 ] && return 0
    printf "\033[%dA" "$lines"
    local i
    for ((i=0; i<lines; i++)); do printf "\033[K\033[1B"; done
    for ((i=1; i<lines; i++)); do printf "\033[1A"; done
}

# Collapse a wizard section to answered (◇). Call at end of a section so ◆ becomes ◇.
# $1=Title, $2=number of lines the section used (header + content lines)
header_tui_collapse() {
    local title="$1"
    local lines="${2:-1}"
    local acc=$(get_accent)
    [ "$lines" -lt 1 ] && return 0
    printf "\033[%dA" "$lines"
    printf "%b%s%b%b%b\033[K\n" "$acc" "$DIAMOND_EMPTY" "$acc" "$title" "$RESET"
    local i
    for ((i=1; i<lines; i++)); do printf "\033[K\033[1B"; done
    for ((i=1; i<lines; i++)); do printf "\033[1A"; done
}
