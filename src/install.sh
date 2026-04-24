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

# ── 1. Docker ────────────────────────────────────────────────────────────────
header_tui "1/11  Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
    _log INSTALL ERROR "Docker is not installed. Install from https://www.docker.com/products/docker-desktop"
    error "Docker is not installed. See https://www.docker.com/products/docker-desktop"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    warn "Docker is installed but not running."
    _log_silent INSTALL WARNING "Docker not running at launch."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        info "Starting Docker Desktop..."
        open -a Docker
        info "Waiting for Docker to start..."
        until docker info >/dev/null 2>&1; do sleep 2; done
    else
        error "Please start Docker and re-run this script."
        exit 1
    fi
fi
success "Docker is ready"

# ── 2. Data directories ─────────────────────────────────────────────────────
header_tui "2/11  Creating data directories"
if [ -d "$HOME/.llm-docker" ] && [ -n "$(ls -A "$HOME/.llm-docker" 2>/dev/null)" ]; then
    info "~/.llm-docker already exists (sessions, auth, SSH keys may live there)."
    ask_yes_no_tui "Wipe and recreate? (No = merge — keep existing files)" "n" WIPE_DIRS 1 0
    if [[ "$WIPE_DIRS" =~ ^[Yy] ]]; then
        if command -v trash >/dev/null 2>&1; then
            trash "$HOME/.llm-docker" 2>/dev/null || true
        else
            mv "$HOME/.llm-docker" "$HOME/.llm-docker.bak.$(date +%Y%m%d%H%M%S)"
        fi
        setup_dirs >/dev/null
        success "~/.llm-docker wiped and recreated"
    else
        setup_dirs >/dev/null
        success "~/.llm-docker merged (existing files kept)"
    fi
else
    setup_dirs >/dev/null
    success "~/.llm-docker/  structure ready"
fi

# ── 3. .env ─────────────────────────────────────────────────────────────────
header_tui "3/11  Setting up .env (secrets)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    success ".env already exists"
else
    setup_env >/dev/null
    success "Seeded .env from template"
fi

# ── 4. Workspace mount ──────────────────────────────────────────────────────
header_tui "4/11  Workspace mirror (optional)"
info "Per-invocation mounts always work: cd into a folder, run cld/ocd, that folder mounts."
info "Enable the persistent mirror to auto-mount WORKSPACE_DIR on every launch."

CURRENT_WS="$(_read_env_var WORKSPACE_DIR "$SCRIPT_DIR/llm-docker.conf")"
DOCKER_DIR_CONF="$(_read_env_var DOCKER_DIR "$SCRIPT_DIR/llm-docker.conf")"
[ -z "$DOCKER_DIR_CONF" ] && DOCKER_DIR_CONF="/root"
[ -z "$CURRENT_WS" ] && CURRENT_WS_PRESET="n" || CURRENT_WS_PRESET="y"

ask_yes_no_tui "Enable the persistent workspace mirror?" "$CURRENT_WS_PRESET" MOUNT_CHOICE 1 0

if [[ "$MOUNT_CHOICE" =~ ^[Yy] ]]; then
    DEFAULT_WS="${CURRENT_WS:-$HOME/Projects}"
    while true; do
        ask_path_tui "Host folder (WORKSPACE_DIR)" "$DEFAULT_WS" NEW_WS "$TREE_MID" 1 0
        EXPANDED_WS="${NEW_WS/#\~/$HOME}"
        NEW_DD="$DOCKER_DIR_CONF/$(basename "$EXPANDED_WS")"
        if [ -z "$NEW_WS" ]; then
            warn "WORKSPACE_DIR required when enabling mirror."
            continue
        fi
        if _validate_workspace_paths "$EXPANDED_WS" "$NEW_DD"; then
            break
        fi
        warn "Try a different path."
        DEFAULT_WS="$NEW_WS"
    done
    _update_conf_var WORKSPACE_DIR "$NEW_WS"
    success "Persistent mirror: ${C5}${NEW_WS}${RESET} ↔ ${secondary_accent}${NEW_DD}${RESET}"
else
    _update_conf_var WORKSPACE_DIR ""
    NEW_WS=""; NEW_DD=""
    success "Per-invocation mode only"
fi

# ── 5. API keys & behavior ──────────────────────────────────────────────────
header_tui "5/11  API keys & behavior"
info "Press Enter on any token to keep its current value. Masked preview shown for existing tokens."

# Anthropic
CUR_ANT="$(_read_env_var ANTHROPIC_API_KEY "$SCRIPT_DIR/.env")"
if [ -n "$CUR_ANT" ]; then
    ask_tui "Anthropic API Key - don't set this and use /login if you have subscription" "$CUR_ANT" NEW_ANTHROPIC "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_ANT")"
else
    ask_tui "Anthropic API Key - don't set this and use /login if you have subscription" "" NEW_ANTHROPIC "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_ANTHROPIC" ] && NEW_ANTHROPIC="$CUR_ANT"

# OpenAI
CUR_OAI="$(_read_env_var OPENAI_API_KEY "$SCRIPT_DIR/.env")"
if [ -n "$CUR_OAI" ]; then
    ask_tui "OpenAI Key" "$CUR_OAI" NEW_OPENAI "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_OAI")"
else
    ask_tui "OpenAI Key" "" NEW_OPENAI "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_OPENAI" ] && NEW_OPENAI="$CUR_OAI"

# Z.AI
CUR_ZAI="$(_read_env_var ZAI_API_KEY "$SCRIPT_DIR/.env")"
if [ -n "$CUR_ZAI" ]; then
    ask_tui "Z.AI API Key" "$CUR_ZAI" NEW_ZAI "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_ZAI")"
else
    ask_tui "Z.AI API Key" "" NEW_ZAI "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_ZAI" ] && NEW_ZAI="$CUR_ZAI"

_update_env_var ANTHROPIC_API_KEY "$NEW_ANTHROPIC"
_update_env_var OPENAI_API_KEY    "$NEW_OPENAI"
_update_env_var ZAI_API_KEY       "$NEW_ZAI"

CUR_EXIT="$(_read_env_var EXIT_TO_DOCKER "$SCRIPT_DIR/llm-docker.conf")"
[ -z "$CUR_EXIT" ] && CUR_EXIT="false"
EXIT_PRESET="n"
[ "$CUR_EXIT" = "true" ] && EXIT_PRESET="y"
ask_yes_no_tui "Drop to container shell on Claude/OpenCode exit (EXIT_TO_DOCKER)?" "$EXIT_PRESET" EXIT_CHOICE 1 0
if [[ "$EXIT_CHOICE" =~ ^[Yy] ]]; then NEW_EXIT="true"; else NEW_EXIT="false"; fi
_update_conf_var EXIT_TO_DOCKER "$NEW_EXIT"
success "API keys + behavior saved"

# ── 6. SSH access ───────────────────────────────────────────────────────────
header_tui "6/11  SSH access (optional)"
info "Public-key auth only. Enabling forces bridge networking (docker -p)."

CUR_SSH_EN="$(_read_env_var LLM_DOCKER_SSH_ENABLED "$SCRIPT_DIR/llm-docker.conf")"
SSH_PRESET="n"
[ "$CUR_SSH_EN" = "true" ] && SSH_PRESET="y"
ask_yes_no_tui "Enable SSH?" "$SSH_PRESET" SSH_CHOICE 1 0

if [[ "$SSH_CHOICE" =~ ^[Yy] ]]; then
    CUR_HOST_PORT="$(_read_env_var LLM_DOCKER_SSH_HOST_PORT "$SCRIPT_DIR/llm-docker.conf")"
    [ -z "$CUR_HOST_PORT" ] && CUR_HOST_PORT="8884"
    ask_tui "Host port (LLM_DOCKER_SSH_HOST_PORT)" "$CUR_HOST_PORT" NEW_HOST_PORT "$TREE_MID" 1 0

    # Discover all ~/.ssh/*.pub files, present as a multi-select checklist.
    PUB_FILES=()
    for f in "$HOME"/.ssh/*.pub; do
        [ -f "$f" ] && PUB_FILES+=("$f")
    done

    NEW_KEY=""
    if [ ${#PUB_FILES[@]} -eq 0 ]; then
        warn "No ~/.ssh/*.pub files found."
        ask_tui "Paste public key" "" PASTE_KEY "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
        NEW_KEY="$PASTE_KEY"
    else
        opts=""
        descs=""
        default_idx=""
        idx=0
        for f in "${PUB_FILES[@]}"; do
            fname="$(basename "$f")"
            key_line="$(cat "$f")"
            key_type="$(printf '%s' "$key_line" | awk '{print $1}')"
            key_cmt="$(printf '%s' "$key_line" | awk '{print $NF}')"
            [ "$key_cmt" = "$key_type" ] && key_cmt="(no comment)"
            [ -n "$opts" ] && opts+=$'\n'
            opts+="$fname"
            [ -n "$descs" ] && descs+=$'\n'
            descs+="${key_type} — ${key_cmt}"
            # Default-check ed25519 first, else first file.
            if [ "$fname" = "id_ed25519.pub" ] && [ -z "$default_idx" ]; then
                default_idx="$idx"
            fi
            idx=$((idx + 1))
        done
        [ -z "$default_idx" ] && default_idx="0"

        checklist_tui "Select public keys to authorize" "$opts" "$descs" "" "$default_idx" SSH_PUBS true 1 0

        # Concatenate selected keys with literal \n (setup-ssh.sh expands via printf %b).
        # checklist_tui writes "true"/"false" into SSH_PUBS_<i>.
        for i in "${!PUB_FILES[@]}"; do
            chosen="$(eval "echo \"\${SSH_PUBS_${i}:-false}\"")"
            if [ "$chosen" = "true" ]; then
                key_content="$(cat "${PUB_FILES[$i]}")"
                [ -n "$NEW_KEY" ] && NEW_KEY="${NEW_KEY}\\n"
                NEW_KEY="${NEW_KEY}${key_content}"
            fi
        done

        ask_tui "Paste an additional public key (optional)" "" PASTE_KEY "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
        if [ -n "$PASTE_KEY" ]; then
            [ -n "$NEW_KEY" ] && NEW_KEY="${NEW_KEY}\\n"
            NEW_KEY="${NEW_KEY}${PASTE_KEY}"
        fi
    fi

    _update_conf_var LLM_DOCKER_SSH_ENABLED      "true"
    _update_conf_var LLM_DOCKER_SSH_HOST_PORT    "$NEW_HOST_PORT"
    _update_conf_var LLM_DOCKER_SSH_PORT         "22"
    _update_env_var  LLM_DOCKER_SSH_AUTHORIZED_KEYS "$NEW_KEY"

    # openssh-server is apt-installed at build time only (install_devpack.sh).
    # Transitioning false→true on an existing image needs a rebuild.
    [ "$CUR_SSH_EN" != "true" ] && _mark_rebuild_needed "SSH enabled (needs openssh-server baked in)"

    if [ -z "$NEW_KEY" ]; then
        warn "No public key saved — SSH will reject every login until you add one."
    fi
    success "SSH enabled — connect with: ${secondary_accent}ssh -p $NEW_HOST_PORT root@localhost${RESET}"

    # Offer the hostname alias so the user can `ssh root@llm-docker` instead.
    if ! grep -qE '^[0-9.]+[[:space:]]+llm-docker(\s|$)' /etc/hosts 2>/dev/null; then
        info "Optional: add ${secondary_accent}llm-docker${RESET} as a hostname alias on your Mac so you can ${secondary_accent}ssh -p $NEW_HOST_PORT root@llm-docker${RESET}"
        info "Run this once (requires sudo):"
        printf "    %becho \"127.0.0.1    llm-docker\" | sudo tee -a /etc/hosts%b\n" "$secondary_accent" "$RESET"
    else
        success "/etc/hosts already has an ${secondary_accent}llm-docker${RESET} entry — you can use ${secondary_accent}ssh root@llm-docker${RESET}"
    fi
else
    _update_conf_var LLM_DOCKER_SSH_ENABLED "false"
    success "SSH disabled"
fi

# ── 7. Builder API (optional) ───────────────────────────────────────────────
header_tui "7/11  Builder API (optional)"
info "Host-side daemon the container calls for build / run / logs / live streaming."
info "What it does: queued builds with whitelisted args, long-poll status, log tail"
info "by alias, a runtime controller for long-lived processes, a /ws event stream,"
info "and a browser console tunnel (window.onerror → event feed). Docs in"
info "${secondary_accent}src/builder-api/README.md${RESET}."
info "Security: password-guarded (X-Builder-API-Password header), rate-limited, "
info "execvp-only (no shell), paths scoped to the project root."

CUR_API_PW="$(_read_env_var BUILDER_API_PASSWORD "$SCRIPT_DIR/.env")"
API_PRESET="n"
[ -n "$CUR_API_PW" ] && API_PRESET="y"
ask_yes_no_tui "Enable Builder API?" "$API_PRESET" API_CHOICE 1 0

if [[ "$API_CHOICE" =~ ^[Yy] ]]; then
    if [ -n "$CUR_API_PW" ]; then
        ask_tui "BUILDER_API_PASSWORD" "$CUR_API_PW" NEW_API_PW "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_API_PW")"
    else
        ask_tui "BUILDER_API_PASSWORD" "" NEW_API_PW "$TREE_MID" 1 0 "" 0 "(pick a strong shared password)"
    fi
    [ -z "$NEW_API_PW" ] && NEW_API_PW="$CUR_API_PW"
    if [ -z "$NEW_API_PW" ]; then
        warn "No password saved — Builder API clients will be rejected until you add one to .env."
    else
        _update_env_var BUILDER_API_PASSWORD "$NEW_API_PW"
        success "Builder API password saved to .env"
    fi
else
    success "Builder API skipped"
fi

# ── 8. Tmux helpers (optional) ──────────────────────────────────────────────
header_tui "8/11  Tmux helpers (optional)"
info "Pick which tmux modes you want for ${secondary_accent}cld${RESET} / ${secondary_accent}ocd${RESET}."
info "Each ticked box bakes its bits into the image. Unticked = not installed."

ask_yes_no_tui "Enable tmux integrations?" "y" TMUX_ENABLE 1 0

# Vanilla tmux is implicit — enabling integrations always bakes `apt tmux` into
# the image. The checklist only surfaces the additive layers on top.
TMUX_CHOICE_FLAGS=(INSTALL_TMUX_TEAM INSTALL_TMUX_RECON INSTALL_TMUX_CODEMAN INSTALL_TMUX_CLAUDE)
TMUX_ALL_FLAGS=(INSTALL_TMUX_VANILLA "${TMUX_CHOICE_FLAGS[@]}")

if [[ "$TMUX_ENABLE" =~ ^[Yy] ]]; then
    TMUX_OPT_LABELS=(
      "tmux team (-tt)       multi-pane team layout (our custom)"
      "recon (-tr)           gavraz/recon dashboard"
      "codeman (-tc)         Ark0N/Codeman web UI on :3000"
      "claude-tmux (-tcl)    nielsgroen/claude-tmux popup (cld only)"
    )
    TMUX_OPT_DESCS=(
      "apt tmux + helper scripts; lead + peers + haiku runner pane"
      "Rust binary — cargo build during image rebuild"
      "Node helper + container auto-publishes :3000"
      "Rust binary + popup bound to Ctrl+b Ctrl+c"
    )

    cur_vanilla="$(_read_env_var INSTALL_TMUX_VANILLA "$SCRIPT_DIR/llm-docker.conf")"
    [ "$cur_vanilla" != "true" ] && _mark_rebuild_needed "INSTALL_TMUX_VANILLA=true"
    _update_conf_var INSTALL_TMUX_VANILLA "true"

    # Pre-tick what's already enabled in conf; default-tick team on fresh install.
    TMUX_DEFAULTS=""
    _any_set=false
    for i in "${!TMUX_CHOICE_FLAGS[@]}"; do
        if [ "$(_read_env_var "${TMUX_CHOICE_FLAGS[$i]}" "$SCRIPT_DIR/llm-docker.conf")" = "true" ]; then
            [ -n "$TMUX_DEFAULTS" ] && TMUX_DEFAULTS+=","
            TMUX_DEFAULTS+="$i"
            _any_set=true
        fi
    done
    [ "$_any_set" = false ] && TMUX_DEFAULTS="0"
    unset _any_set

    TMUX_OPTS=""
    TMUX_DESCS=""
    for i in "${!TMUX_OPT_LABELS[@]}"; do
        [ -n "$TMUX_OPTS" ]  && TMUX_OPTS+=$'\n'
        TMUX_OPTS+="${TMUX_OPT_LABELS[$i]}"
        [ -n "$TMUX_DESCS" ] && TMUX_DESCS+=$'\n'
        TMUX_DESCS+="${TMUX_OPT_DESCS[$i]}"
    done

    checklist_tui "Tmux setups (Space toggles, Enter confirms)" "$TMUX_OPTS" "$TMUX_DESCS" "" "$TMUX_DEFAULTS" TMUX_SEL true 1 0

    for idx in "${!TMUX_CHOICE_FLAGS[@]}"; do
        flag_name="${TMUX_CHOICE_FLAGS[$idx]}"
        chosen="$(eval "echo \"\${TMUX_SEL_${idx}:-false}\"")"
        new_val="false"
        [ "$chosen" = "true" ] && new_val="true"
        cur_val="$(_read_env_var "$flag_name" "$SCRIPT_DIR/llm-docker.conf")"
        if [ "$cur_val" != "$new_val" ]; then
            _mark_rebuild_needed "$flag_name=$new_val"
        fi
        _update_conf_var "$flag_name" "$new_val"
    done
    success "Tmux helpers saved (vanilla tmux included by default)"
else
    for flag_name in "${TMUX_ALL_FLAGS[@]}"; do
        cur_val="$(_read_env_var "$flag_name" "$SCRIPT_DIR/llm-docker.conf")"
        if [ "$cur_val" = "true" ]; then
            _mark_rebuild_needed "$flag_name=false"
        fi
        _update_conf_var "$flag_name" "false"
    done
    success "Tmux integrations skipped — image will not include tmux or any helpers"
fi

# ── 9. Optional devpacks (build-time) ───────────────────────────────────────
header_tui "9/11  Optional devpacks (build-time)"
info "These flags bake extra tooling into the image. Flipping them only takes"
info "effect after ${secondary_accent}docker rmi llm-docker:latest${RESET} forces a rebuild."

DEVPACK_NAMES=(INSTALL_SECURITY INSTALL_RUBY INSTALL_CPP INSTALL_LLVM_CLANG INSTALL_NS INSTALL_MEDIA)
DEVPACK_DESCS=(
  "pentest toolkit: nmap, sqlmap, nuclei, amass (go), nikto (git)"
  "Ruby stack: rbenv + ruby-build + cocoapods"
  "C/C++ basics: make + cmake + gcc"
  "LLVM/Clang toolchain (superset of CPP)"
  "NativeScript CLI + n (Node version manager)"
  "Media tools: ffmpeg + sox + yt-dlp + pipx"
)

# Defaults from current llm-docker.conf (only items currently set to "true").
DEVPACK_DEFAULTS=""
for i in "${!DEVPACK_NAMES[@]}"; do
    cur_val="$(_read_env_var "${DEVPACK_NAMES[$i]}" "$SCRIPT_DIR/llm-docker.conf")"
    if [ "$cur_val" = "true" ]; then
        [ -n "$DEVPACK_DEFAULTS" ] && DEVPACK_DEFAULTS+=","
        DEVPACK_DEFAULTS+="$i"
    fi
done

DEVPACK_OPTS=""
DEVPACK_DESCS_STR=""
for i in "${!DEVPACK_NAMES[@]}"; do
    [ -n "$DEVPACK_OPTS" ] && DEVPACK_OPTS+=$'\n'
    DEVPACK_OPTS+="${DEVPACK_NAMES[$i]}"
    [ -n "$DEVPACK_DESCS_STR" ] && DEVPACK_DESCS_STR+=$'\n'
    DEVPACK_DESCS_STR+="${DEVPACK_DESCS[$i]}"
done
DEVPACK_SKIP_IDX=${#DEVPACK_NAMES[@]}
DEVPACK_OPTS+=$'\n'"Skip (keep current values)"
DEVPACK_DESCS_STR+=$'\n'"Leave every INSTALL_* flag untouched"

checklist_tui "Select devpacks to bake in (Space toggles, Enter confirms)" "$DEVPACK_OPTS" "$DEVPACK_DESCS_STR" "" "$DEVPACK_DEFAULTS" DEVPACK true 1 0

DEVPACK_SKIP_CHOSEN="$(eval "echo \"\${DEVPACK_${DEVPACK_SKIP_IDX}:-false}\"")"
if [ "$DEVPACK_SKIP_CHOSEN" = "true" ]; then
    success "INSTALL_* flags unchanged"
else
    DEVPACK_CHANGED=0
    for i in "${!DEVPACK_NAMES[@]}"; do
        chosen="$(eval "echo \"\${DEVPACK_${i}:-false}\"")"
        new_val="false"
        [ "$chosen" = "true" ] && new_val="true"
        cur_val="$(_read_env_var "${DEVPACK_NAMES[$i]}" "$SCRIPT_DIR/llm-docker.conf")"
        if [ "$cur_val" != "$new_val" ]; then
            DEVPACK_CHANGED=1
        fi
        _update_conf_var "${DEVPACK_NAMES[$i]}" "$new_val"
    done
    if [ "$DEVPACK_CHANGED" = "1" ]; then
        _mark_rebuild_needed "INSTALL_* flags changed"
        success "Devpack flags saved"
    else
        success "Devpack flags saved (no changes)"
    fi
fi

# ── 10. Build image ─────────────────────────────────────────────────────────
header_tui "10/11  Building Docker image"
if docker image inspect llm-docker:latest >/dev/null 2>&1; then
    if [ "$BUILD_CONF_CHANGED" = "1" ]; then
        info "Build-time settings changed ($BUILD_CONF_REASONS) — existing image doesn't reflect them yet."
        ask_yes_no_tui "Rebuild the image now?" "y" REBUILD_CHOICE 1 0
        if [[ "$REBUILD_CHOICE" =~ ^[Yy] ]]; then
            info "Rebuilding — may take a few minutes..."
            setup_image --no-cache
            printf "\033[2J\033[H"
            show_llm-docker_banner
            header_tui "10/11  Building Docker image"
            success "Docker rebuild done"
        else
            warn "Skipped rebuild — image and config are now out of sync. Run ${secondary_accent}docker rmi llm-docker:latest${RESET} and re-run to apply."
        fi
    else
        success "Image already built (delete with 'docker rmi llm-docker:latest' to rebuild)"
    fi
else
    info "First-time build — may take a few minutes..."
    setup_image --no-cache
    printf "\033[2J\033[H"
    show_llm-docker_banner
    header_tui "10/11  Building Docker image"
    success "Docker build done"
fi

# ── 11. Link cld / ocd ──────────────────────────────────────────────────────
header_tui "11/11  Linking cld + ocd to /usr/local/bin"
NEED_SUDO=false
[ ! -w /usr/local/bin ] && NEED_SUDO=true

# If sudo is needed, draw the head-ascii accompaniment + friendly heads-up
# so the user knows WHY macOS is about to ask for their password.
if [ "$NEED_SUDO" = true ] && command -v ywizz_ascii_secondary >/dev/null 2>&1; then
    printf "\n"
    ywizz_ascii_secondary
    printf "\n  ${secondary_accent}🔒 sudo needed${RESET} ${DIM}to symlink ${secondary_accent}cld${RESET}${DIM} and ${secondary_accent}ocd${RESET}${DIM} into /usr/local/bin${RESET}\n"
    # Prime sudo once — subsequent link_cmd calls inherit the timestamp cache.
    sudo -v || { error "sudo required — aborting"; exit 1; }
fi

link_cmd() {
    local CMD="$1"
    local SRC="$SCRIPT_DIR/$CMD"
    local DST="/usr/local/bin/$CMD"
    chmod +x "$SRC"
    if [ "$NEED_SUDO" = true ]; then
        sudo ln -sf "$SRC" "$DST"
    else
        ln -sf "$SRC" "$DST"
    fi
    success "$CMD → $DST"
}
link_cmd cld
link_cmd ocd

# ── Optional: SSH smoke test (before finish banner) ─────────────────────────
SSH_EN_FINAL="$(_read_env_var LLM_DOCKER_SSH_ENABLED "$SCRIPT_DIR/llm-docker.conf")"
if [ "$SSH_EN_FINAL" = "true" ] && [ -x "$SCRIPT_DIR/smoke_test.sh" ]; then
    printf "\n"
    ask_yes_no_tui "Run SSH smoke test now? (starts an ephemeral container and ssh's into it)" "y" RUN_SMOKE 0 0
    if [[ "$RUN_SMOKE" =~ ^[Yy] ]]; then
        "$SCRIPT_DIR/smoke_test.sh" || warn "SSH smoke test reported a failure — check the error above."
    fi
fi

# ── Completion ──────────────────────────────────────────────────────────────
printf "\n"
center_ascii "${secondary_accent}╔══════════════════════════════════════════╗${RESET}" 46
center_ascii "${secondary_accent}║${RESET}     ${C5}(^_^)/  Installation complete!${RESET}       ${secondary_accent}║${RESET}" 46
center_ascii "${secondary_accent}╚══════════════════════════════════════════╝${RESET}" 46
printf "\n"

printf "  ${C2}Usage:${RESET}\n\n"

printf "  ${C4}Claude Code${RESET}                     ${C4}OpenCode${RESET}\n"
printf "  ${C2}cld${RESET}                             ${C2}ocd${RESET}\n"
printf "  ${C2}cld -c${RESET}              Continue    ${C2}ocd -c${RESET}              Continue\n"
printf "  ${C2}cld -c <uuid>${RESET}       Resume      ${C2}ocd -c <uuid>${RESET}       Resume\n"
printf "  ${C2}cld --slot N${RESET}        Slot N      ${C2}ocd --slot N${RESET}        Slot N\n"
printf "  ${C2}cld -c --slot N${RESET}     Restore     ${C2}ocd -c --slot N${RESET}     Restore\n"
printf "  ${C2}cld 4${RESET}               4 windows   ${C2}ocd 4${RESET}               4 windows\n"
printf "  ${C2}cld 4 -c${RESET}            4 + restore ${C2}ocd 4 -c${RESET}            4 + restore\n"
printf "  ${C2}cld -a${RESET}              builder-api ${C2}ocd -a${RESET}              builder-api\n"
printf "  ${C2}cld -- <tool args>${RESET}  passthrough ${C2}ocd -- <tool args>${RESET}  passthrough\n"
printf "\n"

printf "  ${C2}Where data lives:${RESET}\n"
printf "    ${secondary_accent}~/.llm-docker/claude/.claude${RESET}         Sessions, slots, auth\n"
printf "    ${secondary_accent}~/.llm-docker/claude/.config${RESET}         Secondary Claude config\n"
printf "    ${secondary_accent}~/.llm-docker/claude/.claude.json${RESET}    Top-level user config\n"
printf "    ${secondary_accent}~/.llm-docker/opencode/${RESET}              OpenCode config + sessions + cache\n"
printf "    ${secondary_accent}~/.llm-docker/ssh/${RESET}                   SSH host keys (persist across rebuilds)\n"
printf "\n"

if [ -n "$NEW_WS" ] && [ -n "$NEW_DD" ]; then
    printf "  ${C2}Workspace:${RESET}  persistent mirror ${C5}${NEW_WS}${RESET} ↔ ${secondary_accent}${NEW_DD}${RESET}\n"
else
    printf "  ${C2}Workspace:${RESET}  per-invocation only (${DIM}cd FOO && cld → /root/FOO${RESET})\n"
fi
printf "  ${C2}Security:${RESET}   cap_drop ALL · no-new-privileges · narrow mounts\n"
printf "              toggle via ${secondary_accent}SANDBOX_ENABLED${RESET} / ${secondary_accent}INTERNET_ACCESS${RESET} in llm-docker.conf\n"
printf "\n"

if [ ! -f "$SCRIPT_DIR/.env" ] || ! grep -q "^ANTHROPIC_API_KEY=" "$SCRIPT_DIR/.env" 2>/dev/null; then
    warn "Don't forget to add your API keys to .env (or use 'cld' then '/login')"
    printf "\n"
fi

# ── Optional: post-install health check (after finish banner) ───────────────
if [ -x "$SCRIPT_DIR/install_test.sh" ]; then
    ask_yes_no_tui "Run post-install health check? (mounts, tools, sandbox, devpacks)" "y" RUN_HEALTH 0 1
    if [[ "$RUN_HEALTH" =~ ^[Yy] ]]; then
        "$SCRIPT_DIR/install_test.sh" || warn "Health check reported issues — review output above."
    fi
fi
