#!/bin/bash

# --- ywizz Input (Text/Token Input) ---

# $1=Prompt, $2=Default, $3=VarName, $4=Prefix (optional), $5=continuation (optional), $6=last (optional), $7=answer_prompt (optional), $8=secure_enter_ms (optional), $9=empty_display (optional), $10=display_override (optional)
# answer_prompt: when provided, used for collapsed view instead of prompt (e.g. hide "(Enter to use existing/auto)" from summary)
# secure_enter_ms: optional delay (ms) before accepting input; 0 = no delay. Start flush ensures question is shown before read.
# empty_display: when provided and value is empty, show this instead (e.g. "skipped")
# display_override: when provided and default is non-empty, use this for display instead of actual value (e.g. masked token "sk-ant...xyz1")
# INSTALL_AUTO_YES: use displayed default; always stop at password prompts (real read). See AGENTS.md.
ask_tui() {
    local prompt="$1"
    local default="$2"
    local display_default="${default/#$HOME/~}"
    local var_name="$3"
    local prefix="${4:-$TREE_TOP}"
    local continuation="${5:-0}"
    local last_q="${6:-0}"
    local answer_prompt="${7:-}"
    local secure_enter_ms="${8:-0}"
    local empty_display="${9:-}"
    local display_override="${10:-}"
    [ -z "$answer_prompt" ] && answer_prompt="$(ywizz_prompt_without_subtitle "$prompt")"
    [ -n "$display_override" ] && [ -n "$default" ] && display_default="$display_override"

    # When there's no default and the caller gave an empty_display hint, surface
    # it inline as a dim subtitle so it's visible BEFORE the user presses Enter.
    # ywizz_prompt_without_subtitle strips it from the collapsed view.
    if [ -z "$default" ] && [ -n "$empty_display" ]; then
        prompt="${prompt}  ${DIM}${empty_display}${RESET}"
    fi

    # INSTALL_AUTO_YES: accept default and render same as ENTER, except password prompts (user must type)
    if [ -n "${INSTALL_AUTO_YES:-}" ] && [[ ! "$prompt" =~ [Pp]assword ]]; then
        if [ "$continuation" = "1" ]; then
            printf "%b%s%b%b%b\n" "$accent_color" "$DIAMOND_FILLED" "$accent_color" "$prompt" "$RESET"
        else
            printf "%b%s%s%b%b%b\n" "$accent_color" "$prefix" "$DIAMOND_FILLED" "$accent_color" "$prompt" "$RESET"
        fi
        if [ -n "$default" ]; then
            printf "%b%s %b%s%b\n" "$accent_color" "$TREE_MID" "$GREEN" "$display_default" "$RESET"
        else
            printf "%b%s %b\n" "$accent_color" "$TREE_MID" "$RESET"
        fi
        eval "$var_name=\"$default\""
        if [ "$continuation" = "1" ]; then
            local show_val="${display_default:-}"
            [ -z "$show_val" ] && [ -n "$empty_display" ] && show_val="$empty_display"
            [ -n "$display_override" ] && [ -n "$show_val" ] && [ ${#show_val} -gt 12 ] && show_val="${show_val:0:6}...${show_val: -4}"
            printf "\033[2A\r\033[K"
            printf "%b%s%b%b%b\033[K\n" "$accent_color" "$DIAMOND_EMPTY" "$accent_color" "$answer_prompt" "$RESET"
            printf "\r\033[K%b%s %b%s%b\033[K\n" "$accent_color" "$TREE_MID" "$RESET" "$show_val" "$RESET"
            [ "$last_q" = "1" ] && printf "%b%s%b\n" "$accent_color" "${TREE_BOT:0:1}" "$RESET"
        fi
        return 0
    fi
    
    if [ "$continuation" = "1" ]; then
        # Active question (we're asking now) = full diamond; %b for prompt so dim_color etc. render
        printf "%b%s%b%b%b\n" "$accent_color" "$DIAMOND_FILLED" "$accent_color" "$prompt" "$RESET"
    else
        printf "%b%s%s%b%b%b\n" "$accent_color" "$prefix" "$DIAMOND_FILLED" "$accent_color" "$prompt" "$RESET"
    fi
    if [ -n "$default" ]; then
        printf "%b%s %b%s%b " "$accent_color" "$TREE_MID" "$GREEN" "$display_default" "$RESET"
    else
        printf "%b%s %b" "$accent_color" "$TREE_MID" "$RESET"
    fi
    # Flush any keys pressed before question was drawn so they don't confirm immediately
    while read -t 0.01 -r -n 10000 discard; do :; done 2>/dev/null || true
    read -r input
    if [ -z "$input" ]; then
        eval "$var_name=\"$default\""
    else
        eval "$var_name=\"$input\""
    fi
    if [ "$continuation" = "1" ]; then
        # Re-print header with empty diamond (answered) and the entered value so next question doesn't overwrite it.
        # After read, terminal has echoed ENTER as newline so cursor is one line below │ default; move up 2 to reach ◆ line.
        local show_val="${input:-$default}"
        show_val="${show_val/#$HOME/~}"
        [ -z "$show_val" ] && [ -n "$empty_display" ] && show_val="$empty_display"
        if [ -n "$display_override" ] && [ -n "$show_val" ] && [ ${#show_val} -gt 12 ]; then
            show_val="${show_val:0:6}...${show_val: -4}"
        fi
        printf "\033[2A\r\033[K"
        printf "%b%s%b%b%b\033[K\n" "$accent_color" "$DIAMOND_EMPTY" "$accent_color" "$answer_prompt" "$RESET"
        printf "\r\033[K%b%s %b%s%b\033[K\n" "$accent_color" "$TREE_MID" "$RESET" "$show_val" "$RESET"
        printf "\r\033[K"   # clear leftover line from echoed ENTER so no blank line before next prompt
        if [ "$last_q" = "1" ]; then
            printf "%b%s%b\n" "$accent_color" "${TREE_BOT:0:1}" "$RESET"
        fi
    fi
    # Flush any extra buffered keypresses (e.g. rapid ENTER) so they don't leak or echo into next prompt
    while read -t 0.01 -r -n 10000 discard; do :; done 2>/dev/null || true
}
