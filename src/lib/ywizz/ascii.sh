#!/bin/bash

# --- ASCII Art & Animation Library ---
# Extracted and Refactored from ywizz/banner.sh and install_clawfather.sh

# Source theme to ensure colors are available
_ASCII_DIR="$(dirname "${BASH_SOURCE[0]}")"
[ -f "$_ASCII_DIR/theme.sh" ] && source "$_ASCII_DIR/theme.sh"
[ -f "$_ASCII_DIR/core.sh" ] && source "$_ASCII_DIR/core.sh"

# Config from install_clawfather.sh; fallbacks when used standalone
: "${INVERT_COLORS:=OFF}"
: "${ANIMATION_PHASE_SHIFT_ROWS:=0}"
: "${ANIMATION_CYCLES:=1}"
: "${ANIMATION_DIRECTION:=-NW}"

# Re-export center_ascii if not already defined (or for standalone usage)
if ! command -v center_ascii &> /dev/null; then
    center_ascii() {
        local text="$1"
        local width="${2:-101}"
        local term_width
        term_width=$(tput cols 2>/dev/null || echo 100)
        local pad=$(( (term_width - width) / 2 ))
        if [ $pad -gt 0 ]; then
            for ((i=0; i<pad; i++)); do printf " "; done
        fi
        printf "%b\n" "$text"
    }
fi

# draw_banner_frame: [lobster_c1, text_c1, ..., lobster_cN, text_cN, line1, ..., lineN]
# When BANNER_ANIMATE_FRAME is set, footer uses W→E shining animation (palette from GENERATED_PALETTE).
draw_banner_frame() {
    local args=("$@")
    local total=${#args[@]}
    local count=$(( total / 3 ))
    local r="$RESET"

    local ver="${CLAWFATHER_VERSION:-v1.1}"
    local footer_text="${ver} by: Yaro"
    local footer_suffix=""
    if [ -n "${BANNER_ANIMATE_FRAME:-}" ] && [ ${#GENERATED_PALETTE[@]} -gt 0 ]; then
        local p_len=${#GENERATED_PALETTE[@]}
        local frame="${BANNER_ANIMATE_FRAME}"
        local result=""
        local i
        for (( i=0; i<${#footer_text}; i++ )); do
            local c="${footer_text:$i:1}"
            local idx=$(( (i + frame) % p_len ))
            [ "$idx" -lt 0 ] && idx=$(( idx + p_len ))
            result+="${GENERATED_PALETTE[$idx]}${c}${r}"
        done
        footer_suffix="                       ${result}"
    else
        footer_suffix="                       ${accent_color}${footer_text}${r}"
    fi

    for (( i=0; i<count; i++ )); do
        local lobster_c="${args[i]:-$C1}"
        local text_c="${args[i+count]:-$C1}"
        local line="${args[i+2*count]}"
        local lobster_part text_part
        case "$line" in
            *"   /"*) lobster_part="${line%%"   /"*}"; text_part="   /${line#*"   /"}";;
            *"  |"*)  lobster_part="${line%%"  |"*}"; text_part="  |${line#*"  |"}";;
            *"   \\"*) lobster_part="${line%%"   \\"*}"; text_part="   \\${line#*"   \\"}";;
            *)       lobster_part="$line"; text_part="";;
        esac
        if [ $i -eq $(( count - 1 )) ] && [ -z "$text_part" ]; then
            printf "%b%s%b%s\n" "${lobster_c}" "${lobster_part}" "${r}" "$footer_suffix"
        elif [ -n "$text_part" ]; then
            printf "%b%s%b%b%s%b\n" "${lobster_c}" "${lobster_part}" "${r}" "${text_c}" "${text_part}" "${r}"
        else
            printf "%b%s%b\n" "${lobster_c}" "${lobster_part}" "${r}"
        fi
    done
}

animate_banner() {
    # Arguments: $1 $2 $3 = accent colors (kept for API compatibility; banner uses fixed C1..C7)
    # Use banner palette: same row→color mapping as show_banner_combined (C1..C7 gradient)
    generate_banner_palette
    local palette=("${GENERATED_PALETTE[@]}")
    local p_len=${#palette[@]}

    # Capture banner lines from arguments 4 onwards
    local banner_lines=("${@:4}")
    if [ ${#banner_lines[@]} -eq 0 ]; then
        echo "Error: No banner lines provided to animate_banner"
        return 1
    fi
    local num_rows=${#banner_lines[@]}

    local cycles="${ANIMATION_CYCLES:-1}"
    local phase_shift="${ANIMATION_PHASE_SHIFT_ROWS:-0}"
    local endless=0
    [ "$cycles" -eq -1 ] && endless=1
    local total_frames=$(( endless ? 0 : p_len * cycles ))
    local move_up=$num_rows
    local extra_lines=0
    if [ -n "${BANNER_ENDLESS_CALLBACK:-}" ] && type "$BANNER_ENDLESS_CALLBACK" &>/dev/null; then
        extra_lines="${BANNER_ENDLESS_EXTRA_LINES:-0}"
        move_up=$(( move_up + extra_lines ))
    fi

    local dir="${ANIMATION_DIRECTION}"
    dir=$(printf '%s' "$dir" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
    local reverse=0
    case "$dir" in
        -*) dir="${dir#-}"; reverse=1 ;;
    esac
    : "${dir:=NW}"
    trap 'printf "\033[?25h"' EXIT
    printf "\033[?25l"
    local frame=0
    while true; do
        local lobster_colors=() text_frame_colors=()
        for (( r=0; r<num_rows; r++ )); do
            local row_phase
            case "$dir" in
                NW|N|NE) row_phase=$(( r + (reverse ? -frame : frame) )) ;;
                SW|S|SE) row_phase=$(( (num_rows - 1 - r) + (reverse ? -frame : frame) )) ;;
                W)       row_phase=$(( r - frame )) ;;
                E)       row_phase=$(( (num_rows - 1 - r) - frame )) ;;
                *)       row_phase=$(( r + (reverse ? -frame : frame) )) ;;
            esac
            local idx=$(( (row_phase + phase_shift) % p_len ))
            while [ "$idx" -lt 0 ]; do idx=$(( idx + p_len )); done
            lobster_colors+=("${palette[$idx]}")
            text_frame_colors+=("${palette[$idx]}")
        done
        BANNER_ANIMATE_FRAME="$frame"
        draw_banner_frame "${lobster_colors[@]}" "${text_frame_colors[@]}" "${banner_lines[@]}"
        if [ "$extra_lines" -gt 0 ] && [ -n "${BANNER_ENDLESS_CALLBACK:-}" ]; then
            "$BANNER_ENDLESS_CALLBACK"
        fi
        if [ "$endless" -eq 0 ] && [ "$frame" -ge "$total_frames" ]; then
            break
        fi
        printf "\033[%dA" "$move_up"
        sleep 0.02
        frame=$(( frame + 1 ))
    done
    unset BANNER_ANIMATE_FRAME
    sleep 0.08
    printf "\033[?25h"
    trap - EXIT
}

show_palette_debug() {
    local p=( "$@" )
    # Use generated names if available, else generic
    local names=("${GENERATED_NAMES[@]}")

    printf "\n   ${accent_color}--- DYNAMIC COLOR PLATE (${#p[@]} STEPS) ---${RESET}\n"
    for (( i=0; i<${#p[@]}; i++ )); do
        printf "   [%2d] %b██%b  %s\n" "$i" "${p[$i]}" "$RESET" "${names[$i]}"
    done
    printf "\n"
}

# Dual palettes: lobster cycles C1..C7; text uses fixed row colors from show_banner_combined
generate_banner_palette() {
    GENERATED_PALETTE=(
        "$C1" "$C1" "$C2" "$C2" "$C3" "$C3" "$C4" "$C4" "$C5" "$C5" "$C6" "$C6" "$C7" "$C7"
    )
    # Text colors per row (0-13): rows 3-10 have text C1-C8 per show_banner_combined
    GENERATED_TEXT_COLORS=("$C1" "$C1" "$C2" "$C1" "$C2" "$C3" "$C4" "$C5" "$C6" "$C7" "$C8" "$C6" "$C7" "$C7")
    GENERATED_NAMES=(
        "Blue 1" "Blue 1" "Blue 2" "Blue 2" "Cyan 1" "Cyan 1" "Cyan 2" "Cyan 2"
        "Sky Blue" "Sky Blue" "Light Purple" "Light Purple" "Purple" "Purple"
    )
    if [ "${INVERT_COLORS:-OFF}" = "ON" ]; then
        local reversed=()
        local i
        for (( i=${#GENERATED_PALETTE[@]}-1; i>=0; i-- )); do
            reversed+=("${GENERATED_PALETTE[$i]}")
        done
        GENERATED_PALETTE=("${reversed[@]}")
        reversed=()
        for (( i=${#GENERATED_NAMES[@]}-1; i>=0; i-- )); do
            reversed+=("${GENERATED_NAMES[$i]}")
        done
        GENERATED_NAMES=("${reversed[@]}")
    fi
}

# --- ywizz ASCII API: Primary (animated) and Secondary (head) ---
# Content comes from caller via YWIZZ_ASCII_PRIMARY / YWIZZ_ASCII_SECONDARY (install config).
# Colors: BANNER_C_PINK, BANNER_C_BLUE, BANNER_C_LBL for primary; C1..C7 for secondary.

ywizz_ascii_primary() {
    local c1="${BANNER_C_PINK:-$C9}" c2="${BANNER_C_BLUE:-$C2}" c3="${BANNER_C_LBL:-$C4}"
    if [ ${#YWIZZ_ASCII_PRIMARY[@]} -gt 0 ]; then
        animate_banner "$c1" "$c2" "$c3" "${YWIZZ_ASCII_PRIMARY[@]}"
    elif [ $# -ge 4 ]; then
        animate_banner "$1" "$2" "$3" "${@:4}"
    else
        echo "Error: No banner lines. Set YWIZZ_ASCII_PRIMARY or pass lines to ywizz_ascii_primary" >&2
        return 1
    fi
}

ywizz_ascii_secondary() {
    # Same color spectrum as CLAWFATHER banner (GENERATED_TEXT_COLORS) so skull matches when shown alone or combined.
    local colors=("$C1" "$C1" "$C2" "$C2" "$C3" "$C3" "$C4" "$C4" "$C5" "$C5" "$C6" "$C6" "$C7")
    if command -v generate_banner_palette &>/dev/null; then
        generate_banner_palette
        colors=("${GENERATED_TEXT_COLORS[@]}")
    fi
    local lines=()
    if [ ${#YWIZZ_ASCII_SECONDARY[@]} -gt 0 ]; then
        lines=("${YWIZZ_ASCII_SECONDARY[@]}")
    else
        # Fallback when used standalone (no install config)
        lines=(
            '⠀   ⠀⠀⢀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⢀⣠⣤⣼⣿⣿⣿⣾⣶⡤⠄⠀⠀⠀⠀⠀⠀⠀'
            '⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⡀⠀⠀⠀⠀⠀⠀'
            '⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⡄⠀⠀⠀⠀'
            '⢀⣾⢿⣿⣿⡿⠿⠿⠿⠿⢿⣿⣿⡿⣿⢇⠀⠀⠀⠀'
            '⠀⠀⠀⠀⢨⣷⡀⠀⠀⠐⣢⣬⣿⣷⡁⣾⠀⠀⠀⠀'
            '⢀⡠⣤⣴⣾⣿⣿⣷⣦⣿⣿⣿⣿⣿⠿⡇⠀⠀⠀⠀'
            '⠈⠙⣿⡿⠚⠿⠟⢿⣟⣿⣿⣿⣿⣿⠉⠀⠀⠀⠀⠀'
            '⠀⠀⣹⠵⠀⠠⠼⠯⠝⣻⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠻⢂⡄⠒⠒⠛⣿⡿⠛⠻⠋⣼⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠠⡀⠰⠶⠿⠿⠷⠞⠀⣠⣴⠟⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠈⠂⣀⠀⠀⠀⠀⢠⠟⠉⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠘⠓⠂⠀⠐⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀'
        )
    fi
    local i=0
    for line in "${lines[@]}"; do
        local c="${colors[$i]:-$C7}"
        printf "   %b%s%b\n" "$c" "$line" "$RESET"
        i=$(( i + 1 ))
    done
}

# Print secondary ASCII, then flash only the text 3 times (reverse video on text, not whole screen).
ywizz_ascii_secondary_flash() {
    local colors=("$C1" "$C1" "$C2" "$C2" "$C3" "$C3" "$C4" "$C4" "$C5" "$C5" "$C6" "$C6" "$C7")
    if command -v generate_banner_palette &>/dev/null; then
        generate_banner_palette
        colors=("${GENERATED_TEXT_COLORS[@]}")
    fi
    local lines=()
    if [ ${#YWIZZ_ASCII_SECONDARY[@]} -gt 0 ]; then
        lines=("${YWIZZ_ASCII_SECONDARY[@]}")
    else
        lines=(
            '⠀   ⠀⠀⢀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⢀⣠⣤⣼⣿⣿⣿⣾⣶⡤⠄⠀⠀⠀⠀⠀⠀⠀'
            '⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⡀⠀⠀⠀⠀⠀⠀'
            '⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⡄⠀⠀⠀⠀'
            '⢀⣾⢿⣿⣿⡿⠿⠿⠿⠿⢿⣿⣿⡿⣿⢇⠀⠀⠀⠀'
            '⠀⠀⠀⠀⢨⣷⡀⠀⠀⠐⣢⣬⣿⣷⡁⣾⠀⠀⠀⠀'
            '⢀⡠⣤⣴⣾⣿⣿⣷⣦⣿⣿⣿⣿⣿⠿⡇⠀⠀⠀⠀'
            '⠈⠙⣿⡿⠚⠿⠟⢿⣟⣿⣿⣿⣿⣿⠉⠀⠀⠀⠀⠀'
            '⠀⠀⣹⠵⠀⠠⠼⠯⠝⣻⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠻⢂⡄⠒⠒⠛⣿⡿⠛⠻⠋⣼⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠠⡀⠰⠶⠿⠿⠷⠞⠀⣠⣴⠟⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠈⠂⣀⠀⠀⠀⠀⢠⠟⠉⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠘⠓⠂⠀⠐⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀'
        )
    fi
    local num_lines=${#lines[@]}
    local i=0
    for line in "${lines[@]}"; do
        local c="${colors[$i]:-$C7}"
        printf "   %b%s%b\n" "$c" "$line" "$RESET"
        i=$(( i + 1 ))
    done
    # Flash only the text once (reverse video on ASCII, not whole screen)
    for _b in 1; do
        printf "\033[%dA" "$num_lines"
        i=0
        for line in "${lines[@]}"; do
            c="${colors[$i]:-$C7}"
            printf "\033[7m   %b%s%b\033[27m\n" "$c" "$line" "$RESET"
            i=$(( i + 1 ))
        done
        sleep 0.15
        printf "\033[%dA" "$num_lines"
        i=0
        for line in "${lines[@]}"; do
            c="${colors[$i]:-$C7}"
            printf "   %b%s%b\n" "$c" "$line" "$RESET"
            i=$(( i + 1 ))
        done
        sleep 0.15
    done
}

# Legacy alias: show_head_ascii calls ywizz_ascii_secondary
show_head_ascii() {
    ywizz_ascii_secondary
}

# $1 = optional number of lines to clear. Default 18 (show_head_ascii + prompt padding).
# Use 13 to clear only the ASCII art (e.g. before debug command in Hatch flow).
clear_head_ascii() {
    local lines_to_clear="${1:-18}"
    for ((i=0; i<lines_to_clear; i++)); do
        printf "\033[1A\r\033[K"
    done
}

# Alias for clear_head_ascii (ywizz naming)
ywizz_clear_ascii() {
    clear_head_ascii "${1:-18}"
}

# --- Godfather-themed quotes towards OpenClaw (smoke animation) ---
# Use $'\n' for explicit line breaks in a quote.
CLAWFATHER_QUOTES=(
    "I'm gonna make him an"$'\n'"offer he can't refuse..."$'\n'$'\n'"to run in Docker."
    "Leave the skills. Take the gateway."
    "OpenClaw is the family now."
    "Every skill I install, I do for the family."
    "It's not personal, it's containerized."
    "The dashboard is the way to the truth."
    "I believe in OpenClaw. The tools. The skills. The Docker."
    "Don't forget the cannoli. Or the docker compose pull."
    "You come to me on install day and ask for a skill."
    "Revenge is a dish best served with docker compose up -d."
    "The Godfather would have run OpenClaw in a sandbox."
    "Keep your agents close, and your gateway token closer."
)

# Reverse a UTF-8 line for mirror (head looking left)
_reverse_utf8_line() {
    local line="$1"
    if command -v perl &>/dev/null; then
        printf '%s' "$line" | perl -CS -0777 -pe 'chomp; $_=reverse($_)'
    else
        echo "$line"
    fi
}

# Head art facing left (mirrored). Uses YWIZZ_ASCII_SECONDARY if set, else fallback; each line reversed.
_build_head_left_lines() {
    local -a src
    if [ ${#YWIZZ_ASCII_SECONDARY[@]} -gt 0 ]; then
        src=("${YWIZZ_ASCII_SECONDARY[@]}")
    else
        src=(
            '⠀   ⠀⠀⢀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⢀⣠⣤⣼⣿⣿⣿⣾⣶⡤⠄⠀⠀⠀⠀⠀⠀⠀'
            '⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⡀⠀⠀⠀⠀⠀⠀'
            '⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⡄⠀⠀⠀⠀'
            '⢀⣾⢿⣿⣿⡿⠿⠿⠿⠿⢿⣿⣿⡿⣿⢇⠀⠀⠀⠀'
            '⠀⠀⠀⠀⢨⣷⡀⠀⠀⠐⣢⣬⣿⣷⡁⣾⠀⠀⠀⠀'
            '⢀⡠⣤⣴⣾⣿⣿⣷⣦⣿⣿⣿⣿⣿⠿⡇⠀⠀⠀⠀'
            '⠈⠙⣿⡿⠚⠿⠟⢿⣟⣿⣿⣿⣿⣿⠉⠀⠀⠀⠀⠀'
            '⠀⠀⣹⠵⠀⠠⠼⠯⠝⣻⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠻⢂⡄⠒⠒⠛⣿⡿⠛⠻⠋⣼⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠠⡀⠰⠶⠿⠿⠷⠞⠀⣠⣴⠟⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠈⠂⣀⠀⠀⠀⠀⢠⠟⠉⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠘⠓⠂⠀⠐⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀'
        )
    fi
    HEAD_LEFT_LINES=()
    local line reversed
    for line in "${src[@]}"; do
        reversed="$(_reverse_utf8_line "$line")"
        HEAD_LEFT_LINES+=("${reversed//$'\n'/}")
    done
}

# Bubble (smoke) grows from mouth to the right; cloud-shaped word bubble with quote inside.
_BUBBLE_MAX_W=100
_BUBBLE_MAX_H=6
_BUBBLE_CONTENT_LINES=4
_SMOKE_TOTAL_LINES=13

# Word-wrap text to width; respect explicit newlines. Store lines in WRAPPED_LINES (global array).
_wrap_quote_to_width() {
    local text="$1" width="$2"
    WRAPPED_LINES=()
    [ "$width" -lt 1 ] && return
    local normalized="${text//\\n/$'\n'}"
    local segment line word
    while IFS= read -r segment || [ -n "$segment" ]; do
        line=""
        segment="${segment//$'\r'/}"
        [ -z "$segment" ] && { WRAPPED_LINES+=(""); continue; }
        for word in $segment; do
            if [ -z "$line" ]; then
                line="$word"
            elif [ $((${#line} + 1 + ${#word})) -le "$width" ]; then
                line="$line $word"
            else
                WRAPPED_LINES+=("$line")
                line="$word"
            fi
        done
        [ -n "$line" ] && WRAPPED_LINES+=("$line")
    done <<< "$normalized"
}

# Build bubble lines for current frame. _bubble_w, _bubble_h set by caller.
# Uses _bubble_max_quote_width if set. Left edge closed: " ~" and " (" align (one leading space).
# Structure: top ~ (1), content (up to 4 lines), bottom ~ (1 when h>=2). Max height 6.
_build_bubble_lines() {
    local q="${CLAWFATHER_QUOTES[$_smoke_quote_idx]}"
    local w="${_bubble_w:-4}"
    local h="${_bubble_h:-1}"
    local show_text="${_bubble_show_text:-1}"
    BUBBLE_LINES=()
    [ "$h" -le 0 ] && return
    # Inner width: " (" + inner + ") " = w  => inner = w-4
    local max_q=$(( w - 4 ))
    [ "$max_q" -lt 1 ] && max_q=1
    local wrap_width="$max_q"
    if [ -n "${_bubble_max_quote_width:-}" ] && [ "$_bubble_max_quote_width" -lt "$max_q" ]; then
        wrap_width="$_bubble_max_quote_width"
        [ "$wrap_width" -lt 10 ] && wrap_width=10
    fi
    # Cloud top: " ~" + dots + "~ " = w  => top_len = w-4 (left-closed)
    local top_len=$(( w - 4 ))
    [ "$top_len" -lt 0 ] && top_len=0
    local top_mid=""
    for ((i=0; i<top_len; i++)); do top_mid+="·"; done
    BUBBLE_LINES+=(" ~${top_mid}~ ")
    [ "$h" -le 1 ] && return
    local empty_inner=""
    for ((i=0; i<max_q; i++)); do empty_inner+=" "; done
    local -a content=()
    if [ "$show_text" -eq 1 ]; then
        _wrap_quote_to_width "$q" "$wrap_width"
        local i=0
        for ((i=0; i<_BUBBLE_CONTENT_LINES; i++)); do
            if [ "$i" -eq 0 ]; then
                content+=(" (${empty_inner}) ")
            elif [ "$(( i - 1 ))" -lt "${#WRAPPED_LINES[@]}" ]; then
                local ln="${WRAPPED_LINES[$(( i - 1 ))]}"
                local pad=$(( max_q - ${#ln} ))
                local pad_l=0 pad_r=0
                [ "$pad" -gt 0 ] && { pad_l=$(( pad / 2 )); pad_r=$(( pad - pad_l )); }
                local pad_l_str="" pad_r_str=""
                [ "$pad_l" -gt 0 ] && printf -v pad_l_str '%*s' "$pad_l" ''
                [ "$pad_r" -gt 0 ] && printf -v pad_r_str '%*s' "$pad_r" ''
                content+=(" (${pad_l_str}${ln}${pad_r_str}) ")
            else
                content+=(" (${empty_inner}) ")
            fi
        done
    else
        for ((i=0; i<_BUBBLE_CONTENT_LINES; i++)); do
            content+=(" (${empty_inner}) ")
        done
    fi
    local content_count=$(( h - 2 ))
    [ "$content_count" -lt 0 ] && content_count=0
    [ "$content_count" -gt "$_BUBBLE_CONTENT_LINES" ] && content_count="$_BUBBLE_CONTENT_LINES"
    local c=0
    while [ "$c" -lt "$content_count" ]; do
        BUBBLE_LINES+=("${content[$c]}")
        c=$(( c + 1 ))
    done
    local bot_mid=""
    for ((i=0; i<top_len; i++)); do bot_mid+="·"; done
    BUBBLE_LINES+=(" ~${bot_mid}~ ")
}

# Phase lengths (frames at 0.1s each): GROW≈0.3s, SHOW=3s, PUFF≈0.5s, SMOKE=0.8s
_SMOKE_GROW_FRAMES=3
_SMOKE_SHOW_FRAMES=30
_SMOKE_PUFF_FRAMES=5
_SMOKE_WISP_FRAMES=8

# Draw head (left-facing) with smoke/bubble on the RIGHT. Uses _smoke_phase and _smoke_phase_frame.
_draw_head_smoke_frame() {
    local quote_idx="${_smoke_quote_idx:-0}"
    _build_head_left_lines
    local num_rows=${#HEAD_LEFT_LINES[@]}
    local term_cols
    term_cols=$(tput cols 2>/dev/null) || term_cols=80
    [ "$term_cols" -lt 40 ] && term_cols=40
    # So wrap fits terminal and we don't crop text when drawing
    local max_head_len=0 r=0 len
    for ((r=0; r<num_rows; r++)); do
        len=${#HEAD_LEFT_LINES[$r]}
        [ "$len" -gt "$max_head_len" ] && max_head_len=$len
    done
    # Max bubble line width that fits on every row (narrowest row limits it) — keeps bubble closed, never clipped
    local max_bubble_line=$(( term_cols - 5 - max_head_len ))
    [ "$max_bubble_line" -lt 12 ] && max_bubble_line=12
    _bubble_max_quote_width="$max_bubble_line"
    [ "$_bubble_max_quote_width" -lt 10 ] && _bubble_max_quote_width=10
    local f="${_smoke_phase_frame:-0}"
    local phase="${_smoke_phase:-grow}"
    case "$phase" in
        grow)
            _bubble_w=$(( 2 + f * (_BUBBLE_MAX_W - 2) / _SMOKE_GROW_FRAMES ))
            [ "$_bubble_w" -gt "$_BUBBLE_MAX_W" ] && _bubble_w="$_BUBBLE_MAX_W"
            _bubble_h=$(( 1 + f * (_BUBBLE_MAX_H - 1) / _SMOKE_GROW_FRAMES ))
            [ "$_bubble_h" -gt "$_BUBBLE_MAX_H" ] && _bubble_h="$_BUBBLE_MAX_H"
            _bubble_show_text=0
            ;;
        show)
            _bubble_w="$_BUBBLE_MAX_W"
            _bubble_h="$_BUBBLE_MAX_H"
            _bubble_show_text=1
            ;;
        puff)
            _bubble_w=$(( _BUBBLE_MAX_W - f * (_BUBBLE_MAX_W - 2) / _SMOKE_PUFF_FRAMES ))
            [ "$_bubble_w" -lt 2 ] && _bubble_w=2
            _bubble_h=$(( _BUBBLE_MAX_H - f * (_BUBBLE_MAX_H - 1) / _SMOKE_PUFF_FRAMES ))
            [ "$_bubble_h" -lt 1 ] && _bubble_h=1
            _bubble_show_text=$(( f < _SMOKE_PUFF_FRAMES / 2 ? 1 : 0 ))
            ;;
        smoke)
            _bubble_w=$(( 4 + (f % 3) ))
            _bubble_h=1
            _bubble_show_text=0
            ;;
        *) _bubble_w=4; _bubble_h=1; _bubble_show_text=0 ;;
    esac
    # Cap bubble width so it always fits on screen — bubble stays closed (right edge never clipped)
    [ "$_bubble_w" -gt "$max_bubble_line" ] && _bubble_w="$max_bubble_line"
    _build_bubble_lines
    # Mouth row: bubble attaches around row 5 (middle of head)
    local mouth_row=8
    local bubble_start=$(( mouth_row - _bubble_h / 2 ))
    [ "$bubble_start" -lt 0 ] && bubble_start=0
    local r
    for ((r=0; r<num_rows; r++)); do
        local head_line="${HEAD_LEFT_LINES[$r]}"
        local color="${C1}"
        case "$r" in
            0|1) color="$C1" ;;
            2|3) color="$C2" ;;
            4|5) color="$C3" ;;
            6|7) color="$C4" ;;
            8|9) color="$C5" ;;
            10|11) color="$C6" ;;
            *) color="$C7" ;;
        esac
        # Max bubble zone so this row doesn't wrap (approx: 3 spaces + head + 2 spaces + bubble)
        local head_len=${#head_line}
        local max_bubble=$(( term_cols - 5 - head_len ))
        [ "$max_bubble" -lt 0 ] && max_bubble=0
        printf '\r\033[K'
        printf "   %b%s%b" "$color" "$head_line" "$RESET"
        local bi=$(( r - bubble_start ))
        if [ "$bi" -ge 0 ] && [ "$bi" -lt "${#BUBBLE_LINES[@]}" ]; then
            local bline="${BUBBLE_LINES[$bi]}"
            # Bubble width was capped to max_bubble_line so it fits; no truncation (keeps right edge closed)
            # Same coloring as head (gradient per row)
            printf "  %b%s%b" "$color" "$bline" "$RESET"
            local blen=${#bline}
            local pad=$(( max_bubble - blen ))
            [ "$pad" -gt 0 ] && printf '%*s' "$pad" ''
        else
            printf '%*s' "$max_bubble" ''
        fi
        printf "\n"
    done
    _SMOKE_LINES_DRAWN=$num_rows
}

# Run one smoke animation cycle with one random quote, then exit.
# Phases: smoke (wisp) → grow → show quote → puff → exit.
ywizz_head_left_smoke_exit() {
    [ ! -t 1 ] && return 0
    _smoke_quote_idx=$(( RANDOM % ${#CLAWFATHER_QUOTES[@]} ))
    _smoke_phase="smoke"
    _smoke_phase_frame=0
    local frame_delay=0.1
    trap 'printf "\033[?25h"' EXIT
    printf "\033[?25l"
    while true; do
        _draw_head_smoke_frame
        sleep "$frame_delay"
        printf "\033[%dA" "${_SMOKE_LINES_DRAWN:-$_SMOKE_TOTAL_LINES}"
        _smoke_phase_frame=$(( _smoke_phase_frame + 1 ))
        case "$_smoke_phase" in
            grow)
                if [ "$_smoke_phase_frame" -ge "$_SMOKE_GROW_FRAMES" ]; then
                    _smoke_phase="show"
                    _smoke_phase_frame=0
                fi
                ;;
            show)
                if [ "$_smoke_phase_frame" -ge "$_SMOKE_SHOW_FRAMES" ]; then
                    _smoke_phase="puff"
                    _smoke_phase_frame=0
                fi
                ;;
            puff)
                if [ "$_smoke_phase_frame" -ge "$_SMOKE_PUFF_FRAMES" ]; then
                    break
                fi
                ;;
            smoke)
                if [ "$_smoke_phase_frame" -ge "$_SMOKE_WISP_FRAMES" ]; then
                    _smoke_phase="grow"
                    _smoke_phase_frame=0
                fi
                ;;
        esac
    done
    # Clear the animation block and remove the lines so no blank space remains.
    # Clear each line to blank, move back to top of block, then delete N lines (CSI Ps M).
    local lines_to_clear="${_SMOKE_LINES_DRAWN:-$_SMOKE_TOTAL_LINES}"
    local i=0
    while [ "$i" -lt "$lines_to_clear" ]; do
        printf '\r\033[K\n'
        i=$(( i + 1 ))
    done
    printf "\033[%dA" "$lines_to_clear"
    printf "\033[%dM" "$lines_to_clear"
    printf "\033[?25h"
    trap - EXIT 2>/dev/null
    unset _smoke_quote_idx _smoke_phase _smoke_phase_frame _SMOKE_LINES_DRAWN
}
