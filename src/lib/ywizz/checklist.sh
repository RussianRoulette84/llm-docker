#!/bin/bash

# --- ywizz Checklist (Multi-Select Choice) ---

# $1=Prompt, $2=Options, $3=Descriptions, $4=Subtitles, $5=InitialSelectedIndices, $6=VarNamePrefix, $7=CollapsedDescription, $8=continuation, $9=last, $10=secure_enter_ms
# secure_enter_ms: ignore ENTER/Esc for this many ms after menu appears (0 = accept immediately).
# INSTALL_AUTO_YES: use displayed defaults (param 5), same visual as Esc/Enter. See AGENTS.md.
checklist_tui() {
    local prompt="$1"
    IFS=$'\n' read -rd '' -a options <<< "$2" || true
    IFS=$'\n' read -rd '' -a descriptions <<< "$3" || true
    IFS=$'\n' read -rd '' -a subtitles <<< "$4" || true
    local initial_selected="$5"
    local var_prefix="$6"
    local collapsed_description="${7:-true}"
    local continuation="${8:-0}"
    local last_q="${9:-0}"
    local secure_enter_ms="${10:-0}"
    local count=${#options[@]}
    local acc=$(get_accent)
    local selected_idx=0

    # Hide cursor, restore on exit
    tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null || true; exit' INT TERM
    trap 'tput cnorm 2>/dev/null || true' EXIT
    
    # Initialize selection array
    local selections=()
    for ((i=0; i<count; i++)); do
        if [[ ",$initial_selected," == *",$i,"* ]]; then
            selections+=("true")
        else
            selections+=("false")
        fi
    done

    # Count rendered lines: buffer has one \n per line.
    count_rendered_lines() {
        printf '%s' "$1" | wc -l | tr -d ' '
    }

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

    render_checklist() {
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
                printf -v line_str "%b%s%b%s%b\n" "$acc" "$diamond" "$acc" "$shown_prompt" "$RESET"
            else
                printf -v line_str "%b%s%s%b%b%b\n" "$acc" "$TREE_TOP" "$DIAMOND_FILLED" "$acc" "$shown_prompt" "$RESET"
            fi
            buffer+="$line_str"
            # Instructions ONLY if active
            if [ "$active" == "true" ]; then
                printf -v line_str "%b%s %b%s(Space to toggle, Enter to confirm, Esc for defaults)%b\n" "$acc" "$TREE_MID" "$DIM" "" "$RESET"
                buffer+="$line_str"
            fi
        fi
        
        for i in "${!options[@]}"; do
            # When not active (final view), show only selected options
            if [ "$active" == "false" ] && [ "${selections[$i]}" != "true" ]; then
                continue
            fi
            local icon="○"
            local icon_color="${acc}${DIM}"
            local text_color="${acc}${DIM}"
            
            [ "${selections[$i]}" == "true" ] && icon="✔"
            
            if [ "$i" -eq "$selected_idx" ] && [ "$active" == "true" ]; then
                text_color="$row_selected_color"
                icon_color="$row_selected_color"
            else
                if [ "${selections[$i]}" == "true" ]; then
                    [ "$active" == "false" ] && text_color="$RESET" && icon_color="$RESET" || { text_color="$GREEN"; icon_color="$GREEN"; }
                else
                    if [ "$active" == "true" ]; then
                        text_color="$GREEN"
                        icon_color="$GREEN"
                    else
                        text_color="$dim_color"
                        icon_color="$dim_color"
                    fi
                fi
            fi
            
            # Render Item
            printf -v line_str "%b%s %b%s %b%s%b\033[K\n" "$acc" "$TREE_MID" "$icon_color" "$icon" "$text_color" "${options[$i]}" "$RESET"
            buffer+="$line_str"
            
            # Logic for showing descriptions/subtitles
            local show_details="false"
            if [ "$active" == "true" ]; then
                if [ "$collapsed_description" == "false" ] || [ "$i" -eq "$selected_idx" ]; then
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
            : # Omit \033[J so next widget doesn't overwrite our answer lines
        fi
    }

    # Signal Trap
    local resize_req="false"
    trap 'resize_req="true"' WINCH

    render_checklist "true"
    local menu_init_time=$(date +%s 2>/dev/null || echo 0)

    # INSTALL_AUTO_YES: accept displayed defaults (initial_selected), same visual as Esc then Enter
    if [ -n "${INSTALL_AUTO_YES:-}" ]; then
        local move_up=$(count_rendered_lines "$last_rendered_buffer")
        read -r tw th <<< "$(get_dims)"
        if [ "${th:-0}" -gt 0 ] && [ "${move_up:-0}" -ge "$th" ]; then
            printf "\033[2J\033[H"
        elif [ "${move_up:-0}" -gt 0 ]; then
            printf "\033[%dA" "$move_up"
        fi
        printf "\r\033[K\033[J"
        render_checklist "false"
        if [ "$continuation" = "1" ] && [ "$last_q" = "1" ]; then
            printf "%b%s%b\n" "$acc" "${TREE_BOT:0:1}" "$RESET"
        fi
        for i in "${!options[@]}"; do
            eval "${var_prefix}_${i}=\"${selections[$i]}\""
        done
        tput cnorm 2>/dev/null || true
        trap - INT TERM EXIT
        return 0
    fi

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
                                selected_idx=$(( (selected_idx - 1 + count) % count ))
                            elif [[ $seq == "[B" || $seq == "[C" ]]; then
                                selected_idx=$(( (selected_idx + 1) % count ))
                            fi
                        fi
                    fi
                else
                    # ESC for defaults — only accept after question visible for secure_enter_ms
                    local current_time=$(date +%s%N 2>/dev/null | cut -b 1-13 || echo 0)
                    local start_ms=$((menu_init_time * 1000))
                    if [ "$secure_enter_ms" = "0" ] || [ "$current_time" = "0" ] || [ $((current_time - start_ms)) -ge "$secure_enter_ms" ]; then
                        for ((i=0; i<count; i++)); do
                            [[ ",$initial_selected," == *",$i,"* ]] && selections[$i]="true" || selections[$i]="false"
                        done
                        break
                    fi
                fi
            elif [[ $key == "" ]]; then
                # ENTER — only accept after question visible for secure_enter_ms
                local current_time=$(date +%s%N 2>/dev/null | cut -b 1-13 || echo 0)
                local start_ms=$((menu_init_time * 1000))
                if [ "$secure_enter_ms" = "0" ] || [ "$current_time" = "0" ] || [ $((current_time - start_ms)) -ge "$secure_enter_ms" ]; then
                    break
                fi
            elif [[ $key == " " ]]; then
                [ "${selections[$selected_idx]}" == "true" ] && selections[$selected_idx]="false" || selections[$selected_idx]="true"
            fi

            local move_up=$(count_rendered_lines "$last_rendered_buffer")
            read -r tw th <<< "$(get_dims)"
            if [ "${th:-0}" -gt 0 ] && [ "${move_up:-0}" -ge "$th" ]; then
                printf "\033[2J\033[H"
            elif [ "${move_up:-0}" -gt 0 ]; then
                printf "\033[%dA" "$move_up"
            fi
            printf "\033[J"
            render_checklist "true"
        else
            if [ "$resize_req" == "true" ]; then
                resize_req="false"
                local move_up=$(count_rendered_lines "$last_rendered_buffer")
                read -r tw th <<< "$(get_dims)"
                if [ "${th:-0}" -gt 0 ] && [ "${move_up:-0}" -ge "$th" ]; then
                    printf "\033[2J\033[H"
                elif [ "${move_up:-0}" -gt 0 ]; then
                    printf "\033[%dA" "$move_up"
                fi
                printf "\033[J"
                render_checklist "true"
            fi
        fi
    done
    
    # Final Confirm
    local move_up=$(count_rendered_lines "$last_rendered_buffer")
    read -r tw th <<< "$(get_dims)"
    if [ "${th:-0}" -gt 0 ] && [ "${move_up:-0}" -ge "$th" ]; then
        printf "\033[2J\033[H"
    elif [ "${move_up:-0}" -gt 0 ]; then
        printf "\033[%dA" "$move_up"
    fi
    printf "\r\033[K\033[J"
    render_checklist "false"

    if [ "$continuation" = "1" ]; then
        if [ "$last_q" = "1" ]; then
            printf "%b%s%b\n" "$acc" "${TREE_BOT:0:1}" "$RESET"
        fi
    fi

    for i in "${!options[@]}"; do
        eval "${var_prefix}_${i}=\"${selections[$i]}\""
    done
    # Flush any extra buffered keypresses (e.g. rapid ENTER) so they don't leak or echo into next prompt
    while read -t 0.01 -r -n 10000 discard; do :; done 2>/dev/null || true

    tput cnorm 2>/dev/null || true
    trap - INT TERM EXIT
}
