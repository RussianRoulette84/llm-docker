#!/bin/bash

# --- ywizz Progress Bar: Knight Rider style [···∙◦⊙◑·····] / [···◑⊙◦∙·····] ---
# Source core for SPINNER_*, get_accent, RESET
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# Default bar width (dots + trail + ball) — [⊙◐···················]
PROGRESS_BAR_WIDTH_DEFAULT=21
PROGRESS_BAR_EMPTY_CHAR="·"
# Knight Rider trail: dim → bright toward ball (· ∙ ◦ ⊙)
PROGRESS_BAR_TRAIL=("·" "∙" "◦" "⊙")
PROGRESS_BAR_TRAIL_LEN=4

# Build bar contents into variable (Bash 3–compatible: no nameref). No subshell — use in tight animation loops.
# Right: [···∙◦⊙◑·····]  Left: [···◑⊙◦∙·····]
# $1 = output variable name, $2 = width, $3 = position, $4 = spinner frame, $5 = direction (1 or -1)
build_progress_bar_tui() {
    local _out_var=$1
    local width="${2:-$PROGRESS_BAR_WIDTH_DEFAULT}"
    local pos="$3"
    local frame="${4:-0}"
    local dir="${5:-1}"
    local acc
    acc=$(get_accent)
    local empty="$PROGRESS_BAR_EMPTY_CHAR"
    [ "$frame" -ge "${SPINNER_COUNT}" ] && frame=$(( frame % SPINNER_COUNT ))
    if [ "$dir" -eq -1 ]; then
        frame=$(( (SPINNER_COUNT - 1 - frame + SPINNER_COUNT) % SPINNER_COUNT ))
    fi
    local wheel="${SPINNER_FRAMES[$frame]}"
    local trail_len
    if [ "$dir" -eq 1 ]; then
        trail_len=$(( width - 1 - pos ))
    else
        trail_len=$pos
    fi
    [ "$trail_len" -gt "$PROGRESS_BAR_TRAIL_LEN" ] && trail_len=$PROGRESS_BAR_TRAIL_LEN
    [ "$trail_len" -lt 0 ] && trail_len=0

    local bar=""
    local p=0
    while [ "$p" -lt "$width" ]; do
        if [ "$p" -eq "$pos" ]; then
            bar+="${acc}${wheel}${RESET}"
        elif [ "$dir" -eq 1 ]; then
            local d=$(( pos - p ))
            if [ "$d" -ge 1 ] && [ "$d" -le "$trail_len" ]; then
                local idx
                if [ "$trail_len" -le 1 ]; then idx=3
                else idx=$(( 3 - (3 * (d - 1)) / (trail_len - 1) )); fi
                bar+="${acc}${PROGRESS_BAR_TRAIL[$idx]}${RESET}"
            else
                bar+="${empty}${RESET}"
            fi
        else
            local d=$(( p - pos ))
            if [ "$d" -ge 1 ] && [ "$d" -le "$trail_len" ]; then
                local idx
                if [ "$trail_len" -le 1 ]; then idx=3
                else idx=$(( 3 - (3 * (d - 1)) / (trail_len - 1) )); fi
                bar+="${acc}${PROGRESS_BAR_TRAIL[$idx]}${RESET}"
            else
                bar+="${empty}${RESET}"
            fi
        fi
        p=$(( p + 1 ))
    done
    printf -v "$_out_var" '%s' "$bar"
}

# Print the bar contents only (no brackets, no newline). Uses build_progress_bar_tui (subshell-safe for one-off use).
# $1 = width, $2 = position 0..width-1, $3 = spinner frame 0..SPINNER_COUNT-1, $4 = direction (1 or -1)
print_progress_bar_tui() {
    local _tmp
    build_progress_bar_tui _tmp "$@"
    printf "%b" "$_tmp"
}

# Advance position for next frame (bounce 0 -> width-1 -> 0).
# $1 = current position, $2 = direction (1 or -1), $3 = width
# Sets: progress_bar_next_pos, progress_bar_next_dir (caller should eval or source to use)
progress_bar_bounce() {
    local pos="$1"
    local dir="$2"
    local width="${3:-$PROGRESS_BAR_WIDTH_DEFAULT}"
    pos=$(( pos + dir ))
    [ "$pos" -le 0 ] && { pos=0; dir=1; }
    [ "$pos" -ge "$width" ] && { pos=$(( width - 1 )); dir=-1; }
    progress_bar_next_pos=$pos
    progress_bar_next_dir=$dir
}
