# setup/banner.sh — module of the split setup.sh (sourced by the setup.sh loader).

# _iterm_tag TOOL WORKDIR — stamp the iTerm2 tab with "LLM Docker - <TOOL> - /<base>"
# and tint its background Docker blue so LLM sessions pop in a crowded window.
# No-op outside iTerm2 / macOS Terminal (non-iTerm escapes silently ignored).
_iterm_tag() {
    local tool="$1" workdir="$2"
    local base
    base="$(basename "$workdir")"
    # Xterm OSC 0 — window + tab title. Works in iTerm2, macOS Terminal, most emulators.
    printf '\033]0;LLM Docker - %s - /%s\007' "$tool" "$base"
    # iTerm2 OSC 6 — tab background color (Docker blue 36/150/237).
    printf '\033]6;1;bg;red;brightness;36\007'
    printf '\033]6;1;bg;green;brightness;150\007'
    printf '\033]6;1;bg;blue;brightness;237\007'
}
_iterm_untag() {
    # Restore default tab color. Title will be overwritten by the next shell prompt.
    printf '\033]6;1;bg;*;default\007'
}

# Read the version from README.md's shields.io badge (Version-vX.Y).
llm-docker_version() {
    local readme="$SCRIPT_DIR/../README.md"
    local v
    v="$(grep -oE 'Version-v[0-9.]+' "$readme" 2>/dev/null | head -1 | sed 's/Version-//')"
    printf '%s' "${v:-v?}"
}

# Path to the single-source ASCII art. Every caller (setup.sh, install.sh,
# docker-entrypoint.sh) reads from here — no more copy-pasted logos.
LLM_DOCKER_ASCII_FILE="$SCRIPT_DIR/ascii/llm-docker.txt"
LLM_DOCKER_ASCII_WIDTH=50

# print_banner [subtitle] — LLM-DOCKER logo in blue gradient. Colors are
# sampled evenly from C1..C7 so the gradient works for any row count in
# llm-docker.txt (4, 5, 6, … — no hardcoded array).
print_banner() {
    local subtitle="${1:-Your AI cage!}"
    local ver; ver="$(llm-docker_version)"
    local palette=("${C1:-}" "${C2:-}" "${C3:-}" "${C4:-}" "${C5:-}" "${C6:-}" "${C7:-}")
    local p_max=$(( ${#palette[@]} - 1 ))
    local lines=() line
    if [ -f "$LLM_DOCKER_ASCII_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            lines+=("$line")
        done < "$LLM_DOCKER_ASCII_FILE"
    fi
    local n=${#lines[@]}
    local denom=$(( n > 1 ? n - 1 : 1 ))
    local i idx
    for (( i=0; i<n; i++ )); do
        idx=$(( i * p_max / denom ))
        printf "%b%s%b\n" "${palette[$idx]:-}" "${lines[$i]}" "${RST}"
    done
    local ver_pad=$(( (LLM_DOCKER_ASCII_WIDTH - ${#ver}) / 2 ))
    [ "$ver_pad" -lt 0 ] && ver_pad=0
    # xterm-256 141 — one step darker than the subtitle's 177, same hue family.
    local ver_purple=$'\033[38;5;141m'
    printf "%${ver_pad}s%b%s%b\n" "" "$ver_purple" "$ver" "${RST}"
    local sub_pad=$(( (LLM_DOCKER_ASCII_WIDTH - ${#subtitle}) / 2 ))
    [ "$sub_pad" -lt 0 ] && sub_pad=0
    # Purple from the theme (C7 = \033[38;5;177m); fall back to a literal code
    # so the banner still gets colored when theme.sh wasn't sourced.
    local purple="${C7:-$'\033[38;5;177m'}"
    printf "\n%${sub_pad}s%b%s%b\n\n" "" "$purple" "$subtitle" "${RST}"
}

