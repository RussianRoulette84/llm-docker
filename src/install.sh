#!/bin/bash
# llm-docker installer
#
# One-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/llm-docker/master/src/install.sh)
#
# Or from cloned repo:
#   ./src/install.sh

set -e
case "${BASH:-}" in *bash) ;; *) exec /bin/bash "$0" "$@" ;; esac

REPO_URL="https://github.com/RussianRoulette84/llm-docker.git"

# Bootstrap — clone the repo if we were run via curl/pipe (not inside the repo).
if [ ! -f "$(dirname "$0")/Dockerfile" ] 2>/dev/null; then
    DEFAULT_DIR="$(pwd)/llm-docker"
    printf "\n"
    if (( BASH_VERSINFO[0] >= 4 )); then
        read -e -i "$DEFAULT_DIR" -r -p "  Clone llm-docker repo to: " INSTALL_DIR
    else
        read -r -p "  Clone llm-docker repo to [${DEFAULT_DIR}]: " INSTALL_DIR
    fi
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"

    echo ""
    if [ -d "$INSTALL_DIR" ]; then
        echo "  $INSTALL_DIR already exists, pulling latest..."
        git -C "$INSTALL_DIR" pull
    else
        echo "  Cloning llm-docker to $INSTALL_DIR..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    exec "$INSTALL_DIR/src/install.sh"
fi

SCRIPT_DIR="$( cd "$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )" && pwd )"

# Tracks whether any build-time flag (SSH on/off, INSTALL_*) was changed in this
# run. If the image already exists AND this is set, step 9 will offer a rebuild.
BUILD_CONF_CHANGED=0
BUILD_CONF_REASONS=""
_mark_rebuild_needed() {
    BUILD_CONF_CHANGED=1
    [ -n "$BUILD_CONF_REASONS" ] && BUILD_CONF_REASONS+=", "
    BUILD_CONF_REASONS+="$1"
}

# Theme: purple primary, Claude orange secondary. Logo keeps its blue gradient.
source "$SCRIPT_DIR/lib/ywizz/theme.sh"
accent_color="$C7"                  # Purple
dim_color="${C7}${DIM}"
secondary_accent="$ORANGE"          # Claude orange
row_selected_color="\033[1;37m"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ywizz/ywizz.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup.sh"

# --- KV writers (.env + llm-docker.conf) ---
_update_kv() {
    local KEY="$1" VALUE="$2" FILE="$3"
    local ESC
    ESC="$(printf '%s' "$VALUE" | sed 's/[&|\\]/\\&/g')"
    if grep -q "^${KEY}=" "$FILE"; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${KEY}=.*|${KEY}=${ESC}|" "$FILE"
        else
            sed -i "s|^${KEY}=.*|${KEY}=${ESC}|" "$FILE"
        fi
    elif grep -q "^#[[:space:]]*${KEY}=" "$FILE"; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^#[[:space:]]*${KEY}=.*|${KEY}=${ESC}|" "$FILE"
        else
            sed -i "s|^#[[:space:]]*${KEY}=.*|${KEY}=${ESC}|" "$FILE"
        fi
    else
        printf "%s=%s\n" "$KEY" "$VALUE" >> "$FILE"
    fi
}
_update_env_var()  { _update_kv "$1" "$2" "$SCRIPT_DIR/.env"; }
_update_conf_var() { _update_kv "$1" "$2" "$SCRIPT_DIR/llm-docker.conf"; }

_mask_secret() {
    local V="$1"
    if [ "${#V}" -le 4 ]; then
        printf '%s' "$V"
    else
        printf '****%s' "${V: -4}"
    fi
}

# --- LLM-DOCKER banner (blue gradient, animated 1 cycle) ---
show_llm-docker_banner() {
    local W=52
    # Single source of truth — see src/ascii/llm-docker.txt.
    local lines=()
    local _ascii_file="${LLM_DOCKER_ASCII_FILE:-$SCRIPT_DIR/ascii/llm-docker.txt}"
    local _ln
    if [ -f "$_ascii_file" ]; then
        while IFS= read -r _ln || [ -n "$_ln" ]; do
            lines+=("$_ln")
        done < "$_ascii_file"
    fi
    local palette=("$C1" "$C2" "$C3" "$C4" "$C5" "$C6" "$C7")
    local p_len=${#palette[@]}
    local num_lines=${#lines[@]}
    # Sample final (post-animation) colors evenly from the palette so the
    # gradient scales with any row count in llm-docker.txt.
    local final_colors=()
    local _i _idx _denom=$(( num_lines > 1 ? num_lines - 1 : 1 ))
    for (( _i=0; _i<num_lines; _i++ )); do
        _idx=$(( _i * (p_len - 1) / _denom ))
        final_colors+=("${palette[$_idx]}")
    done
    printf "\n"
    # Animate 1 cycle when we have a TTY and not in auto-yes mode
    if [ -t 1 ] && [ -z "${INSTALL_AUTO_YES:-}" ]; then
        printf "\033[?25l"
        local frame=0 r c idx
        while [ "$frame" -lt "$p_len" ]; do
            for (( r=0; r<num_lines; r++ )); do
                idx=$(( (r + frame) % p_len ))
                c="${palette[$idx]}"
                center_ascii "${c}${lines[$r]}${RESET}" "$W"
            done
            printf "\033[%dA" "$num_lines"
            sleep 0.04
            frame=$((frame + 1))
        done
        printf "\033[?25h"
    fi
    local r
    for (( r=0; r<num_lines; r++ )); do
        center_ascii "${final_colors[$r]}${lines[$r]}${RESET}" "$W"
    done
    printf "\n"
    center_ascii "${DIM}${C4}— docker installer ·${RESET} ${secondary_accent}$(llm-docker_version)${RESET} ${DIM}${C4}—${RESET}" 30
    printf "\n"
}

# ──────────────────────────────────────────────────────────────────────────────

[ -t 1 ] && clear || true
show_llm-docker_banner
_log_silent INSTALL "===== install.sh session started @ $(date '+%Y-%m-%d %H:%M:%S') ====="


# ── Steps ────────────────────────────────────────────────────────────────────
# Split into install.d/ for readability. Sourced (NOT subshelled) in order so
# they share one scope — later steps read vars set by earlier ones.
for _step_file in 01-docker 02-dirs 03-env 04-workspace 05-apikeys 06-ssh \
                  07-builderapi 08-tmux 09-devpacks 10-image 11-link 99-complete; do
    if [ ! -f "$SCRIPT_DIR/install.d/${_step_file}.sh" ]; then
        printf 'install.sh: missing step install.d/%s.sh — broken install?\n' "$_step_file" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/install.d/${_step_file}.sh"
done
unset _step_file
