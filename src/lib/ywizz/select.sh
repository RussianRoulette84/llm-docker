#!/bin/bash

# --- ywizz Select (Single Choice) ---

# $1=Prompt, $2=Options, $3=Descriptions, $4=Subtitles, $5=VarName, $6=DefaultIndex, $7=CollapsedDescription, $8=continuation, $9=last, $10=secure_enter_ms
# INSTALL_AUTO_YES: when set, use displayed default (param 6) and render same as interactive (see AGENTS.md).
# secure_enter_ms: ignore ENTER for this many ms after menu appears (0 = accept immediately). Start flush clears prior keys.
select_tui() {
    local prompt="$1"
    IFS=$'\n' read -rd '' -a options <<< "$2" || true
    IFS=$'\n' read -rd '' -a descriptions <<< "$3" || true
    IFS=$'\n' read -rd '' -a subtitles <<< "$4" || true
    local var_name="$5"
    local selected="${6:-0}"
    local collapsed_description="${7:-true}"
    local continuation="${8:-0}"
    local last_q="${9:-0}"
    local secure_enter_ms="${10:-0}"
    local count=${#options[@]}
    local acc=$(get_accent)

    # Hide cursor, restore on exit
    tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null || true; exit' INT TERM
    trap 'tput cnorm 2>/dev/null || true' EXIT
    
    # Standard stdin flush (consumes all pending keys)
    # We use a shorter timeout (0.01s) for better responsiveness
    while read -t 0.01 -r -n 10000 discard; do :; done 2>/dev/null || true

    # Count rendered lines: buffer has one \n per line; no column hacks.
    count_rendered_lines() {
        printf '%s' "$1" | wc -l | tr -d ' '
    }

    # INSTALL_AUTO_YES: accept displayed default (index from param 6), same visual as user pressing ENTER
    if [ -n "${INSTALL_AUTO_YES:-}" ]; then
        get_dims() {
            local cols=80; local lines=24
            command -v tput >/dev/null 2>&1 && { cols=$(tput cols); lines=$(tput lines); }
            echo "$cols $lines"
        }
        last_rendered_buffer=""
        render_options() {
            local active="$1" buffer="" line_str=""
            if [ -n "$prompt" ]; then
                local shown_prompt="$prompt"
                [ "$active" = "false" ] && shown_prompt="$(ywizz_prompt_without_subtitle "$prompt")"
                if [ "$continuation" = "1" ]; then
                    local diamond="$DIAMOND_EMPTY"; [ "$active" = "true" ] && diamond="$DIAMOND_FILLED"
                    printf -v line_str "%b%s%b%s%b\033[K\n" "$acc" "$diamond" "$acc" "$shown_prompt" "$RESET"
                else
                    printf -v line_str "%b%s%s%b%b%b\033[K\n" "$acc" "$TREE_TOP" "$DIAMOND_FILLED" "$acc" "$shown_prompt" "$RESET"
                fi
                buffer+="$line_str"
            fi
            for i in "${!options[@]}"; do
                if [ "$active" == "false" ] && [ "$i" -ne "$selected" ]; then continue; fi
                local opt="${options[$i]}"
                [ "$active" == "false" ] && [[ "$opt" == *"Recommended for ClawFather"* ]] && opt="${opt%%Recommended for ClawFather*}${RESET}"
                if [ "$i" -eq "$selected" ]; then
                    local hl="$row_selected_color"; [ "$active" == "false" ] && hl="$RESET"
                    printf -v line_str "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$hl" "$BULLET_FILLED" "$opt" "$RESET"
                else
                    local nhl="$GREEN"; [ "$active" == "false" ] && nhl="$dim_color"
                    printf -v line_str "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$nhl" "$BULLET_EMPTY" "$opt" "$RESET"
                fi
                buffer+="$line_str"
                local show_details="false"
                if [ "$active" == "true" ]; then
                    [ "$collapsed_description" == "false" ] || [ "$i" -eq "$selected" ] && show_details="true"
                fi
                if [ "$show_details" == "true" ]; then
                    [ -n "${subtitles[$i]}" ] && printf -v line_str "%b%s     %b%s%b\033[K\n" "$acc" "$TREE_MID" "$DIM" "${subtitles[$i]}" "$RESET" && buffer+="$line_str"
                    if [ -n "${descriptions[$i]}" ]; then
                        read -r term_width term_height <<< "$(get_dims)"
                        local wrap_width=$((term_width - 8)); [ "$wrap_width" -lt 40 ] && wrap_width=40
                        local desc_expanded=$(printf "%b" "${descriptions[$i]}")
                        local wrapped_desc=$(echo "$desc_expanded" | fold -w "$wrap_width")
                        while IFS= read -r d_line || [ -n "$d_line" ]; do
                            printf -v line_str "%b%s     %b%s%b\033[K\n" "$acc" "$TREE_MID" "$DIM" "$d_line" "$RESET"
                            buffer+="$line_str"
                        done <<< "$wrapped_desc"
                    fi
                fi
            done
            printf "%s" "$buffer"
            last_rendered_buffer="$buffer"
        }
        render_options "true"
        local move_up=$(count_rendered_lines "$last_rendered_buffer")
        if [ "${move_up:-0}" -gt 0 ]; then printf "\033[%dA" "$move_up"; fi
        printf "\r\033[K\033[J"
        render_options "false"
        if [ "$continuation" = "1" ] && [ "$last_q" = "1" ]; then
            printf "%b%s%b\n" "$acc" "${TREE_BOT:0:1}" "$RESET"
        fi
        eval "$var_name=\"${options[$selected]}\""
        tput cnorm 2>/dev/null || true
        trap - INT TERM EXIT
        return 0
    fi
    
    # Helper: Detect current terminal dimensions
    get_dims() {
        local cols=80
        local lines=24
        if command -v tput >/dev/null 2>&1; then
            cols=$(tput cols)
            lines=$(tput lines)
        fi
        echo "$cols $lines"
    }

    local last_rendered_buffer=""

    render_options() {
        local active="$1"
        local buffer=""
        local line_str=""
        
        # Header
        if [ -n "$prompt" ]; then
            local shown_prompt="$prompt"
            [ "$active" = "false" ] && shown_prompt="$(ywizz_prompt_without_subtitle "$prompt")"
            if [ "$continuation" = "1" ]; then
                # Active (asking) = full diamond; answered (final view) = empty diamond
                local diamond="$DIAMOND_EMPTY"
                [ "$active" = "true" ] && diamond="$DIAMOND_FILLED"
                printf -v line_str "%b%s%b%s%b\033[K\n" "$acc" "$diamond" "$acc" "$shown_prompt" "$RESET"
            else
                printf -v line_str "%b%s%s%b%b%b\033[K\n" "$acc" "$TREE_TOP" "$DIAMOND_FILLED" "$acc" "$shown_prompt" "$RESET"
            fi
            buffer+="$line_str"
        fi
        
        for i in "${!options[@]}"; do
            # When not active (final view), show only the selected option
            if [ "$active" == "false" ] && [ "$i" -ne "$selected" ]; then
                continue
            fi
            local opt="${options[$i]}"
            [ "$active" == "false" ] && [[ "$opt" == *"Recommended for ClawFather"* ]] && opt="${opt%%Recommended for ClawFather*}${RESET}"
            if [ "$i" -eq "$selected" ]; then
                local hl="$row_selected_color"
                [ "$active" == "false" ] && hl="$RESET"
                printf -v line_str "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$hl" "$BULLET_FILLED" "$opt" "$RESET"
                buffer+="$line_str"
            else
                local nhl="$GREEN"
                [ "$active" == "false" ] && nhl="$dim_color"
                printf -v line_str "%b%s %b%s%s%b\033[K\n" "$acc" "$TREE_MID" "$nhl" "$BULLET_EMPTY" "$opt" "$RESET"
                buffer+="$line_str"
            fi
            
            # Logic for showing descriptions/subtitles
            # Shown if: 
            # 1. Menu is active AND (Not collapsed OR this item is selected)
            # 2. Menu is NOT active AND (this item is selected - preserves choice history)
            # However, usually we want to hide descriptions in static mode for "Zen"
            local show_details="false"
            if [ "$active" == "true" ]; then
                if [ "$collapsed_description" == "false" ] || [ "$i" -eq "$selected" ]; then
                    show_details="true"
                fi
            fi

            if [ "$show_details" == "true" ]; then
                # Subtitle (if any)
                if [ -n "${subtitles[$i]}" ]; then
                    printf -v line_str "%b%s     %b%s%b\033[K\n" "$acc" "$TREE_MID" "$DIM" "${subtitles[$i]}" "$RESET"
                    buffer+="$line_str"
                fi
                # Description (if any)
                if [ -n "${descriptions[$i]}" ]; then
                    read -r term_width term_height <<< "$(get_dims)"
                    local wrap_width=$((term_width - 8))
                    [ "$wrap_width" -lt 40 ] && wrap_width=40
                    
                    local desc_expanded=$(printf "%b" "${descriptions[$i]}")
                    local wrapped_desc=$(echo "$desc_expanded" | fold -w "$wrap_width")
                    
                    while IFS= read -r d_line || [ -n "$d_line" ]; do
                        printf -v line_str "%b%s     %b%s%b\033[K\n" "$acc" "$TREE_MID" "$DIM" "$d_line" "$RESET"
                        buffer+="$line_str"
                    done <<< "$wrapped_desc"
                fi
            fi
        done
        printf "%s" "$buffer"
        last_rendered_buffer="$buffer"

        if [ "$active" == "false" ]; then
            : # Omit \033[J so next widget doesn't overwrite our answer line
        fi
    }

    local resize_req="false"
    trap 'resize_req="true"' WINCH

    render_options "true"
    # Record when question became visible (ignore ENTER for secure_enter_ms after this)
    local menu_init_time=$(date +%s 2>/dev/null || echo 0)

    while true; do
        local key=""
        if IFS= read -rs -n 1 -t 1 key; then
            if [[ $key == $'\x1b' ]]; then
                local char=""
                if IFS= read -rs -n 1 -t 1 char 2>/dev/null; then
                    if [[ $char == "[" ]]; then
                        local char2=""
                        if IFS= read -rs -n 1 -t 1 char2 2>/dev/null; then
                            local seq="[$char2"
                            if [[ $seq == "[A" || $seq == "[D" ]]; then
                                selected=$(( (selected - 1 + count) % count ))
                            elif [[ $seq == "[B" || $seq == "[C" ]]; then
                                selected=$(( (selected + 1) % count ))
                            fi
                        fi
                    fi
                fi
            elif [[ $key == "" ]]; then
                # SECURE ENTER: Ignore Enter if pressed within secure_enter_ms of menu init (anti-ghost-input)
                # secure_enter_ms=0: always accept. date +%s%N fails: allow break. Use compatible units (ms).
                local current_time=$(date +%s%N 2>/dev/null | cut -b 1-13 || echo 0)
                local start_ms=$((menu_init_time * 1000))
                if [ "$secure_enter_ms" = "0" ] || [ "$current_time" = "0" ] || [ $((current_time - start_ms)) -ge "$secure_enter_ms" ]; then
                    break
                fi
            fi

            local move_up=$(count_rendered_lines "$last_rendered_buffer")
            read -r tw th <<< "$(get_dims)"
            [ "${th:-0}" -gt 0 ] && [ "${move_up:-0}" -gt "$th" ] && move_up=$th
            if [ "${move_up:-0}" -gt 0 ]; then printf "\033[%dA" "$move_up"; fi
            printf "\033[J"
            render_options "true"
        else
            if [ "$resize_req" == "true" ]; then
                resize_req="false"
                local move_up=$(count_rendered_lines "$last_rendered_buffer")
                read -r tw th <<< "$(get_dims)"
                [ "${th:-0}" -gt 0 ] && [ "${move_up:-0}" -gt "$th" ] && move_up=$th
                if [ "${move_up:-0}" -gt 0 ]; then printf "\033[%dA" "$move_up"; fi
                printf "\033[J"
                render_options "true"
            fi
        fi
    done

    local move_up=$(count_rendered_lines "$last_rendered_buffer")
    if [ "${move_up:-0}" -gt 0 ]; then printf "\033[%dA" "$move_up"; fi
    # \r = start of line; \033[K = clear to EOL; \033[J = clear to end of screen (ensures ◆ is fully cleared)
    printf "\r\033[K\033[J"
    render_options "false"

    if [ "$continuation" = "1" ]; then
        if [ "$last_q" = "1" ]; then
            printf "%b%s%b\n" "$acc" "${TREE_BOT:0:1}" "$RESET"
        fi
    fi

    eval "$var_name=\"${options[$selected]}\""
    # Flush any extra buffered keypresses (e.g. rapid ENTER) so they don't leak or echo into next prompt
    while read -t 0.01 -r -n 10000 discard; do :; done 2>/dev/null || true

    tput cnorm 2>/dev/null || true
    trap - INT TERM EXIT
}
