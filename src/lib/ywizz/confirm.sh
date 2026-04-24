#!/bin/bash

# --- ywizz Confirm (Yes/No Questions) ---

YES_LABEL="Yes"
NO_LABEL="No"

# $1=prompt, $2=default (y/n), $3=var_name, $4=continuation (optional), $5=last (optional), $6=yes_on_right (optional), $7=secure_enter_ms (optional)
# secure_enter_ms: ignore ENTER for this many ms after question appears (0 = accept immediately). Start flush clears prior keys.
# When default is n: options shown as "No / Yes" (reversed), default on left and highlighted
# When yes_on_right=1: always show "No / Yes" (Yes on right), independent of default
# INSTALL_AUTO_YES: use displayed default (param 2), same visual as ENTER. See AGENTS.md.
ask_yes_no_tui() {
    local prompt="$1"
    local default="${2:-y}"
    local selected="$default"
    local var_name="$3"
    local continuation="${4:-0}"
    local last_q="${5:-0}"
    local yes_on_right="${6:-0}"
    local secure_enter_ms="${7:-0}"
    local acc=$(get_accent)
    local answered_prompt
    answered_prompt="$(ywizz_prompt_without_subtitle "$prompt")"
    
    # Standard stdin flush (consumes all pending keys)
    while read -t 0.01 -r -n 10000 discard; do :; done 2>/dev/null || true

    # INSTALL_AUTO_YES: accept default and render same as user pressing ENTER
    if [ -n "${INSTALL_AUTO_YES:-}" ]; then
        if [ "$continuation" = "1" ]; then
            printf "%b%s%b%s%b\n" "$acc" "$DIAMOND_FILLED" "$acc" "$prompt" "$RESET"
        else
            printf "%b%s%s%b%b%b\n" "$acc" "$TREE_TOP" "$DIAMOND_FILLED" "$acc" "$prompt" "$RESET"
        fi
        if [ "$yes_on_right" = "1" ] || [ "$default" = "n" ]; then
            [ "$selected" = "n" ] && printf "\r%b%s %b%s%s%b / %b%s%s%b\n" "$acc" "$TREE_MID" "$GREEN" "$BULLET_FILLED" "$NO_LABEL" "$RESET" "${acc}${DIM}" "$BULLET_EMPTY" "$YES_LABEL" "$RESET"
            [ "$selected" = "y" ] && printf "\r%b%s %b%s%s%b / %b%s%s%b\n" "$acc" "$TREE_MID" "${acc}${DIM}" "$BULLET_EMPTY" "$NO_LABEL" "$RESET" "$GREEN" "$BULLET_FILLED" "$YES_LABEL" "$RESET"
        else
            [ "$selected" = "y" ] && printf "\r%b%s %b%s%s%b / %b%s%s%b\n" "$acc" "$TREE_MID" "$GREEN" "$BULLET_FILLED" "$YES_LABEL" "$RESET" "${acc}${DIM}" "$BULLET_EMPTY" "$NO_LABEL" "$RESET"
            [ "$selected" = "n" ] && printf "\r%b%s %b%s%s%b / %b%s%s%b\n" "$acc" "$TREE_MID" "${acc}${DIM}" "$BULLET_EMPTY" "$YES_LABEL" "$RESET" "$GREEN" "$BULLET_FILLED" "$NO_LABEL" "$RESET"
        fi
        printf "\033[2A\r\033[K"
        printf "%b%s%b%s%b\033[K\n" "$acc" "$DIAMOND_EMPTY" "$acc" "$answered_prompt" "$RESET"
        printf "\r\033[K%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$GREEN" "$BULLET_FILLED" "$([ "$selected" = "y" ] && echo "$YES_LABEL" || echo "$NO_LABEL")" "$RESET"
        [ "$last_q" = "1" ] && printf "%b%s%b\n" "$acc" "${TREE_BOT:0:1}" "$RESET"
        eval "$var_name=\"$selected\""
        return 0
    fi
    
    if [ "$continuation" = "1" ]; then
        # Active question (we're asking now) = full diamond
        printf "%b%s%b%s%b\n" "$acc" "$DIAMOND_FILLED" "$acc" "$prompt" "$RESET"
    else
        printf "%b%s%s%b%b%b\n" "$acc" "$TREE_TOP" "$DIAMOND_FILLED" "$acc" "$prompt" "$RESET"
    fi
    
    # Order: yes_on_right=1 -> "No / Yes"; else default=y -> "Yes / No", default=n -> "No / Yes". Highlight follows selected.
    render_yes_no() {
        if [ "$yes_on_right" = "1" ] || [ "$default" = "n" ]; then
            # Reversed: No on left, Yes on right
            if [ "$selected" = "n" ]; then
                printf "\r%b%s %b%s%s%b / %b%s%s%b" "$acc" "$TREE_MID" "$GREEN" "$BULLET_FILLED" "$NO_LABEL" "$RESET" "${acc}${DIM}" "$BULLET_EMPTY" "$YES_LABEL" "$RESET"
            else
                printf "\r%b%s %b%s%s%b / %b%s%s%b" "$acc" "$TREE_MID" "${acc}${DIM}" "$BULLET_EMPTY" "$NO_LABEL" "$RESET" "$GREEN" "$BULLET_FILLED" "$YES_LABEL" "$RESET"
            fi
        else
            # Normal: Yes on left, No on right
            if [ "$selected" = "y" ]; then
                printf "\r%b%s %b%s%s%b / %b%s%s%b" "$acc" "$TREE_MID" "$GREEN" "$BULLET_FILLED" "$YES_LABEL" "$RESET" "${acc}${DIM}" "$BULLET_EMPTY" "$NO_LABEL" "$RESET"
            else
                printf "\r%b%s %b%s%s%b / %b%s%s%b" "$acc" "$TREE_MID" "${acc}${DIM}" "$BULLET_EMPTY" "$YES_LABEL" "$RESET" "$GREEN" "$BULLET_FILLED" "$NO_LABEL" "$RESET"
            fi
        fi
    }

    render_yes_no
    # Record when question became visible so we ignore ENTER for secure_enter_ms (anti-ghost-input)
    local menu_init_time=$(date +%s 2>/dev/null || echo 0)

    while true; do
        read -rs -n 1 key
        if [[ $key == $'\x1b' ]]; then
            read -rs -n 2 -t 1 key
            if [[ $key == "[A" || $key == "[B" || $key == "[C" || $key == "[D" ]]; then
                if [ "$selected" = "y" ]; then selected="n"; else selected="y"; fi
            fi
        elif [[ $key == "" ]]; then # Enter — only accept after question was visible for secure_enter_ms
            local current_time=$(date +%s%N 2>/dev/null | cut -b 1-13 || echo 0)
            local start_ms=$((menu_init_time * 1000))
            if [ "$secure_enter_ms" = "0" ] || [ "$current_time" = "0" ] || [ $((current_time - start_ms)) -ge "$secure_enter_ms" ]; then
                break
            fi
        elif [[ $key == "y" || $key == "Y" ]]; then
            selected="y"; break
        elif [[ $key == "n" || $key == "N" ]]; then
            selected="n"; break
        fi
        render_yes_no
    done
    if [ "$continuation" = "1" ]; then
        # Re-print header with empty diamond (answered) and the selected answer so next question doesn't overwrite it
        # Cursor is on Yes/No line (render_yes_no uses \r, no \n); we have 2 lines (prompt + options).
        # Move up 1 only (we're on options line; prompt is 1 above), then clear and re-print both lines.
        printf "\033[1A\r\033[K"
        printf "%b%s%b%s%b\033[K\n" "$acc" "$DIAMOND_EMPTY" "$acc" "$answered_prompt" "$RESET"
        printf "\r\033[K"
        if [ "$yes_on_right" = "1" ] || [ "$default" = "n" ]; then
            [ "$selected" = "n" ] && printf "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$RESET" "$BULLET_FILLED" "$NO_LABEL" "$RESET"
            [ "$selected" = "y" ] && printf "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$RESET" "$BULLET_FILLED" "$YES_LABEL" "$RESET"
        else
            [ "$selected" = "y" ] && printf "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$RESET" "$BULLET_FILLED" "$YES_LABEL" "$RESET"
            [ "$selected" = "n" ] && printf "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$RESET" "$BULLET_FILLED" "$NO_LABEL" "$RESET"
        fi
        if [ "$last_q" = "1" ]; then
            printf "%b%s%b\n" "$acc" "${TREE_BOT:0:1}" "$RESET"
        fi
    fi
    # Flush any extra buffered keypresses (e.g. rapid ENTER) so they don't leak or echo into next prompt
    while read -t 0.01 -r -n 10000 discard; do :; done 2>/dev/null || true
    eval "$var_name=\"$selected\""
}
