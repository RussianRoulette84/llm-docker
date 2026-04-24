#!/bin/bash

# --- ywizz Progress Indicators ---
# Uses progress_bar.sh for Knight Rider [···∙◦⊙◑·····] (print_progress_bar_tui)

# Print a "loading" header line: ◆ Title (active section = full diamond).
# Use for any section that is running work (installing, applying config, etc.) not waiting for user.
# Progress bar (e.g. wait_for_condition_tui) uses spinner inside the bar only.
# $1 = title, $2 = ignored (kept for compat), $3 = optional "no_newline" or 1
print_loading_header_tui() {
    local title="$1"
    local no_nl="${3:-}"
    local acc=$(get_accent)
    if [[ "$no_nl" == "1" || "$no_nl" == "no_newline" ]]; then
        printf "\r\033[K%b%s%b%b%b" "$acc" "$DIAMOND_FILLED" "$acc" "$title" "$RESET"
    else
        printf "%b%s%b%b%b\n" "$acc" "$DIAMOND_FILLED" "$acc" "$title" "$RESET"
    fi
}

# Wait for a condition command to return 0, with a cool "Bouncing Ball" animation
# $1 = Message (e.g. "Waiting for gateway...")
# $2 = Check Command (eval'd)
# $3 = Timeout (seconds)
# $4 = Optional fail message (e.g. "Pairing failed" — shown on timeout instead of $1)
wait_for_condition_tui() {
    local message="$1"
    local check_cmd="$2"
    local timeout="${3:-60}"
    local fail_message="${4:-$message}"
    local acc=$(get_accent)
    
    # Hide cursor
    printf "\033[?25l"
    trap 'printf "\033[?25h"' EXIT

    local start_time=$(date +%s)
    
    # Animation Config: spinning wheel (◐◑◒◓) bouncing left-right (bar from progress_bar.sh)
    local width=$PROGRESS_BAR_WIDTH_DEFAULT
    local i=0
    local pos=0
    local dir=1

    while true; do
        local now_ts=$(date +%s)
        local elapsed=$((now_ts - start_time))
        
        # 1. Check Timeout
        if [ "$elapsed" -ge "$timeout" ]; then
             printf "\r\033[K"
             printf "%b %b %b%s (Timed out)%b\n" "${TUI_PREFIX:-$acc}" "${RED}[FAIL]${RESET}" "$RED" "$fail_message" "$RESET" >&2
             # Flush stdin
             while read -r -t 0.01 -n 10000 discard 2>/dev/null; do :; done || true
             printf "\033[?25h"
             trap - EXIT
             return 1
        fi

        # 2. Check Condition (throttled: every 5 frames = 0.5s)
        if (( i % 5 == 0 )); then
            if eval "$check_cmd"; then
                 printf "\r\033[K"
                 # Final "Done" state: back to tree prefix (no spinner)
                 if [[ "$message" == Waiting* ]]; then
                     printf "%b %b %s\n" "$TUI_PREFIX" "${CYAN}[INFO]${RESET}" "$message" >&2
                 else
                     printf "%b %b %b%s%b\n" "$TUI_PREFIX" "${GREEN}[ OK ]${RESET}" "${GREEN}" "$message" "$RESET" >&2
                 fi
                 # Flush stdin (Crucial to prevent skipping following prompts)
                 while read -r -t 0.05 -n 10000 discard 2>/dev/null; do :; done || true
                 printf "\033[?25h"
                 trap - EXIT
                 return 0
            fi
        fi

        # 3. Progress bar: Knight Rider [···∙◦⊙◑·····] via progress_bar.sh (no subshell)
        progress_bar_bounce "$pos" "$dir" "$width"
        pos=$progress_bar_next_pos
        dir=$progress_bar_next_dir
        local wheel_idx=$(( i % SPINNER_COUNT ))
        local bar_str
        build_progress_bar_tui bar_str "$width" "$pos" "$wheel_idx" "$dir"

        # 4. Print: │  [ INFO ] Message... [···∙◦⊙◑·····] 9s/60s
        printf "\r%b %b %s %b[%b%b]" "$TUI_PREFIX" "${CYAN}[INFO]${RESET}" "$message" "$RESET" "$bar_str" "$RESET"
        
        sleep 0.06
        i=$((i + 1))
    done
}

# Run a command with Knight Rider progress bar. Shows bar until command completes.
# $1 = message (e.g. "Installing clawhub...")
# $2 = full command string (eval'd)
# $3 = optional label for output (e.g. NPM, BUN, PNPM). Omit or pass "" for no label.
# stdout+stderr captured; printed after with [ LABEL ] prefix when label set. Returns command exit code.
run_with_progress_bar() {
    local message="$1"
    local cmd="$2"
    local _label="${3:-}"
    local _label_uc _label_color
    local width="${PROGRESS_BAR_WIDTH_DEFAULT:-21}"
    local _out_file=$(mktemp 2>/dev/null || echo "/tmp/npm_out_$$")
    local _rc_file="${_out_file}.rc"
    local _printed_lines=0

    # Label color: keep semantic colors for log levels.
    # Per project policy, package managers (npm/pnpm/bun/pip/brew/apt/apk) use orange.
    _label_uc="$(printf '%s' "$_label" | tr '[:lower:]' '[:upper:]')"
    case "$_label_uc" in
        DEBUG) _label_color="$DIM$CYAN" ;;
        INFO)  _label_color="$CYAN" ;;
        WARN|WARNING) _label_color="$YELLOW" ;;
        ERR|ERROR|FAIL) _label_color="$RED" ;;
        OK|DONE|SUCCESS) _label_color="$GREEN" ;;
        NPM|PNPM|BUN|PIP|BREW|APT|APK) _label_color="${ORANGE:-$YELLOW}" ;;
        *) _label_color="$(get_accent)" ;;
    esac

    printf "\033[?25l"
    ( eval "$cmd" > "$_out_file" 2>&1; echo $? > "$_rc_file" ) &
    local _bg_pid=$!

    local pos=0 dir=1 i=0
    while kill -0 ${_bg_pid} 2>/dev/null; do
        progress_bar_bounce "$pos" "$dir" "$width"
        pos=$progress_bar_next_pos
        dir=$progress_bar_next_dir
        local wheel_idx=$(( i % SPINNER_COUNT ))
        local bar_str
        build_progress_bar_tui bar_str "$width" "$pos" "$wheel_idx" "$dir"
        if [[ -n "$_label" ]]; then
            printf "\r%b %b[%s]%b %b[%b%b] %s" "${TUI_PREFIX:-$(get_accent)}" "${_label_color}" "$_label" "$RESET" "$RESET" "$bar_str" "$RESET" "$message"
        else
            printf "\r%b %b[%b%b] %s" "${TUI_PREFIX:-$(get_accent)}" "$RESET" "$bar_str" "$RESET" "$message"
        fi
        sleep 0.06
        i=$((i + 1))
    done

    wait $_bg_pid 2>/dev/null || true
    printf "\r\033[K"
    printf "\033[?25h"

    local _rc=$(cat "$_rc_file" 2>/dev/null || echo 1)
    if [ -n "${INSTALL_DEBUG:-}" ] && [ -f "$_out_file" ]; then
        while IFS= read -r _line; do
            if [ -n "$_line" ]; then
                _printed_lines=$((_printed_lines + 1))
                if [[ -n "$_label" ]]; then
                    if [[ "$_line" =~ [eE]rror ]]; then
                        printf "%b %b[%s][ERROR]%b %b%s%b\n" "${TUI_PREFIX:-}" "$RED" "$_label" "$RESET" "$RED" "$_line" "$RESET"
                    else
                        printf "%b %b[%s]%b %b%s%b\n" "${TUI_PREFIX:-}" "${_label_color}" "$_label" "$RESET" "$CYAN" "$_line" "$RESET"
                    fi
                else
                    if [[ "$_line" =~ [eE]rror ]]; then
                        printf "%b %b[ERROR]%b %b%s%b\n" "${TUI_PREFIX:-}" "$RED" "$RESET" "$RED" "$_line" "$RESET"
                    else
                        printf "%b %b%s%b\n" "${TUI_PREFIX:-}" "$CYAN" "$_line" "$RESET"
                    fi
                fi
            fi
        done < "$_out_file"
    fi

    # Expose how many log lines were printed so callers can keep header_tui_collapse line math correct.
    # (If INSTALL_DEBUG is unset, we print no command output and this stays 0.)
    RUN_WITH_PROGRESS_BAR_LINES="$_printed_lines"
    rm -f "$_out_file" "$_rc_file"
    return $_rc
}
