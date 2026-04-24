#!/bin/bash

# --- ywizz Banner (Visual Headers & ASCII) ---

# Centering helper for ASCII art
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

show_lobster() {
    printf "\n"
    local W=10
    center_ascii "${C1}⠀   ⠀⠀⢀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C1}⠀⠀⢀⣠⣤⣼⣿⣿⣿⣾⣶⡤⠄⠀⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C2}⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⡀⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C2}⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⡄⠀⠀⠀⠀${NC}" $W
    center_ascii "${C3}⢀⣾⢿⣿⣿⡿⠿⠿⠿⠿⢿⣿⣿⡿⣿⢇⠀⠀⠀⠀${NC}" $W
    center_ascii "${C3}⠀⠀⠀⠀⢨⣷⡀⠀⠀⠐⣢⣬⣿⣷⡁⣾⠀⠀⠀⠀${NC}" $W
    center_ascii "${C4}⢀⡠⣤⣴⣾⣿⣿⣷⣦⣿⣿⣿⣿⣿⠿⡇⠀⠀⠀⠀${NC}" $W
    center_ascii "${C4}⠈⠙⣿⡿⠚⠿⠟⢿⣟⣿⣿⣿⣿⣿⠉⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C5}⠀⠀⣹⠵⠀⠠⠼⠯⠝⣻⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C5}⠀⠀⠻⢂⡄⠒⠒⠛⣿⡿⠛⠻⠋⣼⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C6}⠀⠀⠠⡀⠰⠶⠿⠿⠷⠞⠀⣠⣴⠟⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C6}⠀⠀⠀⠈⠂⣀⠀⠀⠀⠀⢠⠟⠉⠀⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C7}⠀⠀⠀⠀⠀⠘⠓⠂⠀⠐⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C7}⠀⠀⠀⠀⠀⠀⠀⠐⡒⣂⣤⣤⠀⠀⠀⠀⠀⠀⠀⠀${NC}" $W
    center_ascii "${C8}⠀⠀⠀⠸⣿⣿⣿⣿⣿⣿⣿⣿⡟⠀⠀⠀⢀⠤⠄⡀${NC}" $W
    center_ascii "${C8}⠀⠀⠀⠀⣿⣿⣿⣿⣿⣿⣿⣿⡇⠀⠀⢀⡜⠠⢂⡗${NC}" $W
    center_ascii "${C9}⠀⠀⠀⠀⢻⣿⣿⣿⣿⣿⣿⣿⠇⠀⠀⠀⢓⠢⢬⡟${NC}" $W
    center_ascii "${C9}⠀⠀⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀⠀⢸⠍⠀  ${NC}" $W
    printf "\n"
}

show_head() {
    printf "\n"
    printf "   %b\n" "${C1}⠀   ⠀⠀⢀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C1}⠀⠀⢀⣠⣤⣼⣿⣿⣿⣾⣶⡤⠄⠀⠀⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C2}⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⡀⠀⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C2}⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⡄⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C3}⢀⣾⢿⣿⣿⡿⠿⠿⠿⠿⢿⣿⣿⡿⣿⢇⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C3}⠀⠀⠀⠀⢨⣷⡀⠀⠀⠐⣢⣬⣿⣷⡁⣾⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C4}⢀⡠⣤⣴⣾⣿⣿⣷⣦⣿⣿⣿⣿⣿⠿⡇⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C4}⠈⠙⣿⡿⠚⠿⠟⢿⣟⣿⣿⣿⣿⣿⠉⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C5}⠀⠀⣹⠵⠀⠠⠼⠯⠝⣻⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C5}⠀⠀⠻⢂⡄⠒⠒⠛⣿⡿⠛⠻⠋⣼⠀⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C6}⠀⠀⠠⡀⠰⠶⠿⠿⠷⠞⠀⣠⣴⠟⠀⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C6}⠀⠀⠀⠈⠂⣀⠀⠀⠀⠀⢠⠟⠉⠀⠀⠀⠀⠀⠀⠀${NC}"
    printf "   %b\n" "${C7}⠀⠀⠀⠀⠀⠘⠓⠂⠀⠐⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀${NC}"
    printf "\n"
}

show_colors() {
    printf "   %b[ TUI Color Palette ]%b\n" "$CYAN" "$RESET"
    printf "   %bC1: ######%b  %bC2: ######%b  %bC3: ######%b\n" "$C1" "$RESET" "$C2" "$RESET" "$C3" "$RESET"
    printf "   %bC4: ######%b  %bC5: ######%b  %bC6: ######%b\n" "$C4" "$RESET" "$C5" "$RESET" "$C6" "$RESET"
    printf "   %bC7: ######%b  %bC8: ######%b  %bC9: ######%b\n" "$C7" "$RESET" "$C8" "$RESET" "$C9" "$RESET"
    printf "   %bdim:  ####%b (Dim Component)\n\n" "$dim_color" "$RESET"
}
