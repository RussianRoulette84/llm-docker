#!/bin/bash

# --- ywizz Security (Warnings & Disclaimers) ---

style_security_warning() {
    printf "\n"
    local acc=$(get_accent)
    local title="Security warning — please read "
    local target_width=93 # Total visual width including borders
    
    # 1. Top Line: ◆ (2) + title (lenT) + dashes + ╮ (1) = target_width
    local title_len=${#title}
    # ◆ is 2 chars. ╮ is 1 char.
    local top_dashes=$(( target_width - 2 - title_len - 1 ))

    printf "%b%s %s%b" "$acc" "$DIAMOND_EMPTY" "$title" "$RESET"
    printf "%b" "$acc"
    for ((i=0; i<top_dashes; i++)); do printf "─"; done
    printf "╮%b\n" "$RESET"
    
    # 2. Middle Lines: │ (2) + space(2) + content (len) + pad + │ (1) = target_width
    render_line() {
        local content="$1"
        # Strip SGR codes so padding uses visible length when content has BOLD/RESET
        local visible_content; visible_content=$(printf '%s' "$content" | sed $'s/\033\\[[0-9;]*m//g')
        local len=${#visible_content}
        local pad=$(( target_width - 5 - len ))
        printf "%b%s%b  %s" "$acc" "$TREE_MID" "$RESET" "$content"
        for ((i=0; i<pad+1; i++)); do printf " "; done
        printf "%b%s%b\n" "$acc" "${TREE_MID:0:1}" "$RESET"
    }

    render_line ""
    render_line "${BOLD}ClawFather${RESET} is a hobby project created to fire up ${BOLD}OpenClaw${RESET} inside a secure Docker."
    render_line ""
    render_line "It's still in beta. Expect sharp edges."
    render_line "${BOLD}OpenClaw${RESET} bot can read files and run actions if tools are enabled."
    render_line "A bad prompt can trick it into doing unsafe things."
    render_line ""
    render_line "If you’re not comfortable with basic security and access control, don’t run ${BOLD}OpenClaw${RESET}."
    render_line "Ask someone experienced to help before enabling tools or exposing it to the internet."
    render_line ""
    render_line "${BOLD}Recommended baseline:${RESET}"
    render_line "- Pairing/allowlists + mention gating."
    render_line "- Sandbox + least-privilege tools."
    render_line "- Keep secrets out of the agent’s reachable filesystem."
    render_line "- Use the strongest available model for any bot with tools or untrusted inboxes."
    render_line ""
    render_line "${BOLD}Run regularly:${RESET}"
    render_line "docker compose exec openclaw-gateway node dist/index.js security audit --deep"
    render_line "docker compose exec openclaw-gateway node dist/index.js security audit --fix"
    render_line ""
    # Clickable link (OSC 8) + cyan; render manually so padding uses visible length only
    local link_url="https://docs.openclaw.ai/gateway/security"
    local link_visible_len=54   # "Must read: " (11) + URL (43)
    local link_pad=$(( target_width - 5 - link_visible_len ))
    local osc8_start=$'\033]8;;'"$link_url"$'\033\\'
    local osc8_end=$'\033]8;;\033\\'
    printf "%b%s%b  Must read: %b%s%b%s%b%s" "$acc" "$TREE_MID" "$RESET" "$osc8_start" "$CYAN" "$link_url" "$RESET" "$osc8_end"
    for ((i=0; i<link_pad+1; i++)); do printf " "; done
    printf "%b%s%b\n" "$acc" "  ${TREE_MID:0:1}" "$RESET" # 2 extra white spaces for padding
    render_line ""

    # 3. Bottom Line: ├ (T -90°, stem left) + dashes + ┬ (stem down) = target_width
    # Dash count = target_width - 2
    local bot_dashes=$(( target_width - 2 ))
    printf "%b%s" "$acc" "├" # ├ = T rotated -90°, connects │ below
    for ((i=0; i<bot_dashes+1; i++)); do printf "─"; done
    printf "╯%b\n" "$RESET"
    # No connector line — keep wizard consistent (no extra newline between steps)
}
