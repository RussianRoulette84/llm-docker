#!/bin/bash
# First-time setup for llm-docker
# Called automatically by cld/ocd when needed.
# Source of truth for dir/env/image setup — install.sh reuses these functions.

SCRIPT_DIR="$( cd "$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )" && pwd )"

# --- Palette + banner (inlined from former src/ascii.sh). Single source of
# truth for colors lives in lib/ywizz/theme.sh; the legacy RST/GRN/STEP_COLOR
# names are preserved for backward compat with older callers.
_YWIZZ_THEME="$SCRIPT_DIR/lib/ywizz/theme.sh"
if [ -f "$_YWIZZ_THEME" ]; then
    # shellcheck disable=SC1090
    source "$_YWIZZ_THEME"
fi

RST="${RESET:-$'\033[0m'}"
GRN="${GREEN:-$'\033[38;5;82m'}"
STEP_COLOR="${C2:-$'\033[38;5;39m'}"

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

# ── Log sink ───────────────────────────────────────────────────────────────
LOG_DIR="$( cd "$SCRIPT_DIR/.." && pwd )/logs"
LOG_FILE="$LOG_DIR/llm-docker.log"

# LOG_MAX_KILOBYTES: env > llm-docker.conf > 1024. 0 disables file logging.
if [ -z "${LOG_MAX_KILOBYTES:-}" ] && [ -f "$SCRIPT_DIR/llm-docker.conf" ]; then
    LOG_MAX_KILOBYTES="$(grep -E '^LOG_MAX_KILOBYTES=' "$SCRIPT_DIR/llm-docker.conf" 2>/dev/null | head -1 | cut -d= -f2-)"
    LOG_MAX_KILOBYTES="${LOG_MAX_KILOBYTES#\"}"; LOG_MAX_KILOBYTES="${LOG_MAX_KILOBYTES%\"}"
    LOG_MAX_KILOBYTES="${LOG_MAX_KILOBYTES#\'}"; LOG_MAX_KILOBYTES="${LOG_MAX_KILOBYTES%\'}"
fi
case "${LOG_MAX_KILOBYTES:-}" in
    ''|*[!0-9]*) LOG_MAX_KILOBYTES=1024 ;;
esac
export LOG_MAX_KILOBYTES
LOG_MAX_BYTES=$(( LOG_MAX_KILOBYTES * 1024 ))

_log_ensure_dir() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"
}

# macOS uses -f%z, GNU uses -c%s.
_log_file_size() {
    [ -f "$1" ] || { echo 0; return; }
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

# Drop oldest ~10% when file exceeds LOG_MAX_BYTES.
_log_rotate_if_needed() {
    [ "$LOG_MAX_BYTES" -eq 0 ] && return 0
    [ -f "$LOG_FILE" ] || return 0
    local size; size="$(_log_file_size "$LOG_FILE")"
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        local keep=$(( LOG_MAX_BYTES - LOG_MAX_BYTES / 10 ))
        tail -c "$keep" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null \
            && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

_log_write_file() {
    [ "$LOG_MAX_BYTES" -eq 0 ] && return 0
    _log_ensure_dir
    printf '%s\n' "$1" >> "$LOG_FILE"
    _log_rotate_if_needed
}

# _log SOURCE [ERROR|WARNING|INFO] MESSAGE... — stdout + file.
_log() {
    local source="$1"; shift
    local level=""
    case "${1:-}" in
        ERROR|WARNING|INFO)
            level="[$1]"
            shift
            ;;
    esac
    local line="[$source]${level} $*"
    printf '%s\n' "$line"
    _log_write_file "$line"
}

# _log_silent — file only.
_log_silent() {
    local source="$1"; shift
    local level=""
    case "${1:-}" in
        ERROR|WARNING|INFO)
            level="[$1]"
            shift
            ;;
    esac
    _log_write_file "[$source]${level} $*"
}

# _docker_format_line RAW COLS — classify a raw "[DOCKER] ..." log line by
# tool (npm/apt/pip/...) and level (WRN/ERR), wrap the label in colors, and
# set _DOCKER_FMT to the resulting display string (truncated to COLS).
_docker_format_line() {
    local raw="$1" cols="$2"
    local content="${raw#\[DOCKER\] }"
    # Drop BuildKit "#N " prefix so classification sees the real content.
    if [[ "$content" =~ ^#[0-9]+[[:space:]]+ ]]; then
        content="${content#"${BASH_REMATCH[0]}"}"
    fi
    # Drop leading elapsed timestamp ("258.9 ...") so tool keywords surface.
    if [[ "$content" =~ ^[0-9]+(\.[0-9]+)?[[:space:]]+ ]]; then
        content="${content#"${BASH_REMATCH[0]}"}"
    fi

    local tool=""
    case "$content" in
        'npm '*|'npm:'*|'npm WARN'*|'npm ERR'*|'npm http'*|'npm notice'*|'added '*' packages'*)
            tool="NPM" ;;
        'npx '*) tool="NPX" ;;
        'apt-get '*|'apt '*|'dpkg '*|'E: '*|'Reading package lists'*|'Building dependency tree'*|'Reading state information'*|'Setting up '*|'Unpacking '*|'Selecting previously unselected '*|'Preparing to unpack '*|'Get:'*|'Fetched '*)
            tool="APT" ;;
        'pip '*|'pip3 '*|'pipx '*|'Collecting '*|'Requirement already '*|'Successfully installed '*|'Downloading '*whl*|'Installing collected packages'*)
            tool="PIP" ;;
        'cargo '*|'   Compiling '*|'    Compiling '*|'   Downloading crate'*|'    Downloading crate'*|'   Downloaded '*|'    Downloaded '*|'    Finished '*|'   Finished '*|'    Updating '*|'   Updating '*|'    Fresh '*|'   Fresh '*)
            tool="CARGO" ;;
        'gem '*|'Fetching '*'.gem'*|'Installing '*'.gem'*)
            tool="GEM" ;;
        'go '*|'go: '*) tool="GO" ;;
        'curl:'*|'curl '*) tool="CURL" ;;
        '[DEVPACK]'*) tool="DEVPACK" ;;
        'node '*|'node:'*) tool="NODE" ;;
        *) tool="" ;;
    esac

    local level=""
    case "$content" in
        *'ERROR'*|*'error:'*|*'Error:'*|*'ERR!'*|*'failed'*|*'FAILED'*|*'Failed'*|'E: '*)
            level="ERR" ;;
        *'WARNING'*|*'warning:'*|*'Warning:'*|*'WARN '*|*'warn:'*|'W: '*)
            level="WRN" ;;
    esac

    local col_base="${CYAN:-}"
    local col_tool=""
    # NPM/NPX in brown (256-color 130) — red collides with the ERR level color.
    local _BROWN=$'\033[38;5;130m'
    case "$tool" in
        NPM|NPX)   col_tool="$_BROWN" ;;
        APT)       col_tool="${GREEN:-}" ;;
        PIP)       col_tool="${YELLOW:-}" ;;
        NODE)      col_tool="${GREEN:-}" ;;
        CARGO)     col_tool="${ORANGE:-}" ;;
        GEM)       col_tool="${C9:-}" ;;
        GO)        col_tool="${C3:-}" ;;
        CURL)      col_tool="${C5:-}" ;;
        DEVPACK)   col_tool="${C7:-}" ;;
    esac
    local col_level=""
    case "$level" in
        WRN) col_level="${YELLOW:-}" ;;
        ERR) col_level="${RED:-}" ;;
    esac

    local label="${col_base}[DOCKER]${RESET}"
    [ -n "$tool" ]  && label+="${col_tool}[${tool}]${RESET}"
    [ -n "$level" ] && label+="${col_level}[${level}]${RESET}"

    # Plain-text label length for truncation math (strip ANSI would be slow; reconstruct).
    local plain="[DOCKER]"
    [ -n "$tool" ]  && plain+="[${tool}]"
    [ -n "$level" ] && plain+="[${level}]"
    # Visible layout = "  <label> <content>" — 2 indent + label + 1 space + content.
    # Subtract 5 to keep a safety margin so wrapping can't kick in at col boundary.
    local avail=$(( cols - ${#plain} - 5 ))
    [ "$avail" -lt 10 ] && avail=10
    # Strip any control chars so \r / \b / tabs can't bust the crop math.
    content="${content//$'\r'/}"
    content="${content//$'\t'/ }"
    if [ "${#content}" -gt "$avail" ]; then
        content="${content:0:$((avail - 1))}…"
    fi

    _DOCKER_FMT="${label} ${content}"
}

# _docker_pretty RAW — set _DOCKER_PRETTY to a human-friendly summary of a
# BuildKit log line. Pure bash (no forks) so it's cheap to call in the 0.15s
# spinner loop. Empty _DOCKER_PRETTY = "suppress this tick"; the spinner
# keeps showing the previous line so progress stays readable.
_docker_pretty() {
    _DOCKER_PRETTY=""
    local line="$1"
    line="${line#\[DOCKER\] }"
    if [[ "$line" =~ ^#[0-9]+[[:space:]]+ ]]; then
        line="${line#"${BASH_REMATCH[0]}"}"
    fi
    case "$line" in
        ''|' '*)                                          return ;;
        *' DONE '*|*' CACHED'|*' ERROR '*|*' extracting '*) return ;;
        *transferring*|*'load metadata'*|*'load build'*|*'load .dockerignore'*) return ;;
        'naming to '*|'exporting '*|'writing image'*|'auth:'*|'resolve '*) return ;;
        # Tool-progress noise — keep the previous [DEVPACK] banner visible.
        # rustup:   "44.41 info: downloading 3 components"
        # cargo:    "   Compiling foo v0.1.0", "   Downloading crates ..."
        # npm/node: "added 234 packages in 12s", "npm WARN deprecated ..."
        [0-9]*' info: '*|[0-9]*' warn: '*|'info: '*|'warn: '*)               return ;;
        *'  Compiling '*|*'  Downloading '*|*'  Downloaded '*|*'  Finished '*|*'  Installing '*|*'  Fresh '*|*'  Updating '*) return ;;
        'added '*' packages'*|'npm WARN '*|'npm notice '*|'npm http '*)      return ;;
    esac
    local step=""
    if [[ "$line" == \[*\]\ * ]]; then
        step="${line%%]*}]"
        line="${line#*] }"
    fi
    case "$line" in
        *claude-code*|*'@anthropic-ai/claude-code'*)
            line="installing claude-code" ;;
        *opencode-ai*)
            line="installing opencode" ;;
        'RUN apt-get install'*|'RUN apt-get update'*|'RUN apt install'*|'RUN apt update'*)
            line="installing apt packages" ;;
        'RUN pip install'*|'RUN pip3 install'*|'RUN pipx install'*)
            line="installing python packages" ;;
        'RUN npm install'*|'RUN pnpm install'*|'RUN pnpm add'*|'RUN yarn '*|'RUN bun install'*)
            line="installing node packages" ;;
        'RUN gem install'*)     line="installing ruby gems"     ;;
        'RUN cargo install'*)   line="installing cargo crates"  ;;
        'RUN brew install'*)    line="installing brew packages" ;;
        'RUN git clone'*)       line="cloning git repo"         ;;
        'RUN curl '*|'RUN wget '*)              line="downloading"              ;;
        'RUN mkdir '*)                          line="creating directories"     ;;
        'RUN ln '*)                             line="creating symlinks"        ;;
        'RUN chmod '*|'RUN chown '*)            line="fixing permissions"       ;;
        'RUN locale-gen'*)                      line="generating locales"       ;;
        'RUN sh -c'*ohmyzsh*|*'ohmyzsh/install.sh'*)
            line="installing oh-my-zsh" ;;
        'RUN '*)
            local body="${line#RUN }"
            body="${body//\\}"
            body="${body//  / }"
            [ ${#body} -gt 40 ] && body="${body:0:37}..."
            line="run: $body"
            ;;
        'COPY '*)
            local rest="${line#COPY }"
            line="copy: ${rest%% *}"
            ;;
        'ADD '*)
            local rest="${line#ADD }"
            line="add: ${rest%% *}"
            ;;
        'FROM '*)
            local img="${line#FROM }"
            line="base image: ${img%% *}"
            ;;
        'WORKDIR '*)  line="workdir: ${line#WORKDIR }" ;;
        'ENV '*)      line="env: ${line#ENV }"         ;;
        'EXPOSE '*)   line="expose: ${line#EXPOSE }"   ;;
    esac
    if [ -n "$step" ]; then
        _DOCKER_PRETTY="$step $line"
    else
        _DOCKER_PRETTY="$line"
    fi
}

# _count_apt_array — count tokens inside a single-line bash array
# `NAME=(a b c)` literal in $1. All SW_*_APT arrays in install_devpack.sh
# are single-line, so this is enough.
_count_apt_array() {
    local file="$1" name="$2"
    grep -E "^${name}=\(" "$file" 2>/dev/null | head -1 \
        | sed -E "s/^${name}=\(//; s/\\).*\$//" \
        | tr -s ' \t' '\n' \
        | grep -cE '[a-zA-Z]'
}

# _count_total_packages — total install ops the build will perform.
# An "op" is one apt package (Dockerfile RUN apt-get install + each enabled
# SW_*_APT array in install_devpack.sh) or one non-apt step (npm install -g
# call, git clone, curl|sh installer, gem/pip/cargo/go install). The spinner
# counts completion markers in the build log and divides by this total to
# get an honest, monotonic percentage. Replaces the old wall-time-weighted
# guesstimate that jumped erratically when its hardcoded step shape shifted.
_count_total_packages() {
    local conf="$SCRIPT_DIR/llm-docker.conf"
    local dockerfile="$SCRIPT_DIR/Dockerfile"
    local devpack="$SCRIPT_DIR/docker/install_devpack.sh"
    local total=0

    # ── Dockerfile apt blocks. Join `\`-continued lines into single logical
    # lines; for each line containing `apt-get install`, take the slice
    # between that and the next `&&` (or EOL) and count tokens that don't
    # start with `-`.
    if [ -f "$dockerfile" ]; then
        local joined ln pkgs t
        joined=$(awk 'BEGIN{ORS=""} /\\$/{sub(/\\$/,""); print; next} {print $0 "\n"}' "$dockerfile")
        while IFS= read -r ln; do
            [[ "$ln" != *"apt-get install"* ]] && continue
            pkgs="${ln##*apt-get install}"
            pkgs="${pkgs%%&&*}"
            for t in $pkgs; do
                case "$t" in
                    -*|"") continue ;;
                    *) total=$((total + 1)) ;;
                esac
            done
        done <<< "$joined"
    fi

    # ── install_devpack.sh apt arrays, gated by the matching INSTALL_* flag.
    if [ -f "$devpack" ] && [ -f "$conf" ]; then
        local map=(
            "SW_SECURITY_APT:INSTALL_SECURITY"
            "SW_RUBY_APT:INSTALL_RUBY"
            "SW_CPP_APT:INSTALL_CPP"
            "SW_LLVM_CLANG_APT:INSTALL_LLVM_CLANG"
            "SW_MEDIA_APT:INSTALL_MEDIA"
            "SW_QUAKE_APT:INSTALL_QUAKE"
            "SW_BROWSING_APT:INSTALL_BROWSING"
        )
        local entry arr flag c
        for entry in "${map[@]}"; do
            arr="${entry%%:*}"; flag="${entry##*:}"
            [ "$(_read_env_var "$flag" "$conf")" = "true" ] || continue
            c=$(_count_apt_array "$devpack" "$arr")
            total=$(( total + c ))
        done
        # openssh-server (1) when SSH on; tmux (1) when any tmux-helper flag on.
        [ "$(_read_env_var LLM_DOCKER_SSH_ENABLED "$conf")" = "true" ] && total=$(( total + 1 ))
        local f any_tmux=false
        for f in INSTALL_TMUX_VANILLA INSTALL_TMUX_TEAM INSTALL_TMUX_RECON INSTALL_TMUX_CODEMAN INSTALL_TMUX_CLAUDE; do
            [ "$(_read_env_var "$f" "$conf")" = "true" ] && any_tmux=true
        done
        [ "$any_tmux" = true ] && total=$(( total + 1 ))
    fi

    # ── Always-run non-apt ops in the Dockerfile.
    total=$(( total + 1 ))   # npm i -g pnpm
    total=$(( total + 1 ))   # oh-my-zsh installer (sh -c)
    total=$(( total + 3 ))   # zsh-autosuggestions + zsh-syntax-highlighting + powerlevel10k git clones
    total=$(( total + 1 ))   # uv installer (curl | sh)

    # ── install_cli.sh. TOOL build-arg defaults to "both" — opencode + claude
    # + Claude's post-install (install.cjs). Hyperframes skill add when
    # INSTALL_BROWSING is on.
    total=$(( total + 3 ))
    [ "$(_read_env_var INSTALL_BROWSING "$conf")" = "true" ] && total=$(( total + 1 ))

    # ── install_devpack.sh non-apt ops, gated by enabled flags.
    if [ "$(_read_env_var INSTALL_SECURITY "$conf")" = "true" ]; then
        total=$(( total + 1 ))   # Go toolchain tarball download+unpack
        total=$(( total + 5 ))   # 5 go install targets in SW_SECURITY_GO
        total=$(( total + 1 ))   # feroxbuster prebuilt download
        total=$(( total + 1 ))   # nikto git clone
    fi
    [ "$(_read_env_var INSTALL_RUBY "$conf")" = "true" ]    && total=$(( total + 1 ))   # cocoapods gem
    [ "$(_read_env_var INSTALL_NS "$conf")"   = "true" ]    && total=$(( total + 1 ))   # n + nativescript via one npm i -g
    [ "$(_read_env_var INSTALL_MEDIA "$conf")" = "true" ]   && total=$(( total + 1 ))   # yt-dlp + pipx via one pip install
    [ "$(_read_env_var INSTALL_TMUX_RECON "$conf")"   = "true" ]  && total=$(( total + 2 ))   # rustup + cargo recon
    [ "$(_read_env_var INSTALL_TMUX_CLAUDE "$conf")"  = "true" ]  && total=$(( total + 1 ))   # cargo claude-tmux
    [ "$(_read_env_var INSTALL_TMUX_CODEMAN "$conf")" = "true" ]  && total=$(( total + 1 ))   # codeman installer (curl|bash)

    [ "$total" -lt 1 ] && total=1
    printf '%d' "$total"
}

# Pipe stdout/stderr through [DOCKER] prefix, tee to LOG_FILE. Don't use
# for `docker run -it` — the pipe breaks the TTY.
#
# DEBUG=true  → tee to terminal + file (loud mode, prior behavior).
# DEBUG=false → file only, show a spinner. Pulls DEBUG from llm-docker.conf
#               if the env var isn't already set.
_log_docker_exec() {
    _log_ensure_dir
    local _debug="${DEBUG:-}"
    if [ -z "$_debug" ] && [ -f "$SCRIPT_DIR/llm-docker.conf" ]; then
        _debug="$(_read_env_var DEBUG "$SCRIPT_DIR/llm-docker.conf" 2>/dev/null || true)"
    fi

    if [ "$_debug" = "true" ]; then
        set -o pipefail
        if [ "$LOG_MAX_BYTES" -eq 0 ]; then
            "$@" 2>&1 | sed -u $'s/\r/\\n/g' | sed -u 's/^/[DOCKER] /'
        else
            "$@" 2>&1 | sed -u $'s/\r/\\n/g' | sed -u 's/^/[DOCKER] /' | tee -a "$LOG_FILE"
        fi
        local rc=${PIPESTATUS[0]}
        set +o pipefail
        [ "$LOG_MAX_BYTES" -ne 0 ] && _log_rotate_if_needed
        return "$rc"
    fi

    # Silent mode: background the pipeline (pipefail inside the subshell so
    # docker's exit code survives), show a 7-row live panel:
    #   row 1  — │ ◐ 23% - Building Docker
    #   row 2..7 — last 6 raw [DOCKER]... lines with colored tool/level labels.
    #
    # Write to a per-invocation BUILD_LOG so concurrent cld/ocd --build runs
    # don't interleave into the same tail (that was the "stuck on codeman +
    # duplicate lines" bug). The shared LOG_FILE still gets the same stream
    # appended for after-the-fact `tail logs/llm-docker.log`.
    local acc="${accent_color:-}"
    local mid="${TREE_MID:-│ }"
    local BUILD_LOG
    BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/llm-docker-build-$$.XXXXXX" 2>/dev/null)" || BUILD_LOG="/tmp/llm-docker-build-$$.log"
    : >"$BUILD_LOG"
    (
        set -o pipefail
        if [ "$LOG_MAX_BYTES" -eq 0 ]; then
            "$@" 2>&1 | sed -u $'s/\r/\\n/g' | sed -u 's/^/[DOCKER] /' | tee -a "$BUILD_LOG" >/dev/null
        else
            "$@" 2>&1 | sed -u $'s/\r/\\n/g' | sed -u 's/^/[DOCKER] /' | tee -a "$BUILD_LOG" >>"$LOG_FILE"
        fi
    ) &
    local bg_pid=$!
    local frames=("◐" "◑" "◒" "◓")
    local i=0
    # Monotonic pct floor: never let the displayed percentage go backwards,
    # even if a tick's log-parse reads a stale/partial state.
    local _last_pct=0
    # Precompute total install-ops (apt packages + non-apt ops). The pct
    # comes from counting completion markers in the build log and dividing
    # by this total — no weights, no wall-time guesses, no jumping.
    local _total_pkgs
    _total_pkgs="$(_count_total_packages)"
    [ "${_total_pkgs:-0}" -lt 1 ] 2>/dev/null && _total_pkgs=1
    # Reserve 7 rows by printing 7 newlines (terminal scrolls if needed),
    # then move cursor back up 7 rows to the top of the reserved block.
    # Relative cursor-up is scroll-safe; save/restore (\033[s/\033[u) isn't.
    printf '\n\n\n\n\n\n\n'
    printf '\033[7A'
    printf "\033[?25l"
    trap 'printf "\033[?25h"' EXIT
    while kill -0 "$bg_pid" 2>/dev/null; do
        local spin="${frames[$((i % 4))]}"
        # Always re-read terminal width each tick (window may be resized
        # mid-build). Read from /dev/tty so subshell pipe context can't fool
        # tput/stty into returning the default 80.
        local cols=""
        if [ -r /dev/tty ]; then
            cols="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
            [ -z "$cols" ] && cols="$(tput cols </dev/tty 2>/dev/null)"
        fi
        [ -z "$cols" ] && cols="${COLUMNS:-80}"
        [ "$cols" -lt 40 ] 2>/dev/null && cols=40

        # Percent: count actual completion markers in the build log and
        # divide by the pre-computed total of install ops. One marker per:
        #   apt:   `Setting up <pkg>:<arch> (<ver>) ...`        — dpkg per-package
        #   npm:   `added <N> packages` line                    — one per npm install
        #   pip:   `Successfully installed <pkg>...`            — one per pip / gem call
        #   gem:   shares `Successfully installed` with pip
        #   cargo: `   Installing /usr/local/bin/<bin>`         — one per cargo install
        #   git:   `Resolving deltas: 100%`                     — one per git clone
        # No wall-time weights, no BuildKit step-id math, no can-go-backwards
        # `done_n / max_n` lie. Final monotonic clamp below covers regex jitter.
        local pct=0
        if [ -s "$BUILD_LOG" ]; then
            local _apt _npm _pip_gem _cargo _git _done
            _apt=$(grep -cE '^\[DOCKER\] Setting up '         "$BUILD_LOG" 2>/dev/null) || _apt=0
            _npm=$(grep -cE 'added [0-9]+ package'            "$BUILD_LOG" 2>/dev/null) || _npm=0
            _pip_gem=$(grep -cE 'Successfully installed '     "$BUILD_LOG" 2>/dev/null) || _pip_gem=0
            _cargo=$(grep -cE '^[[:space:]]*Installing /'     "$BUILD_LOG" 2>/dev/null) || _cargo=0
            _git=$(grep -cE 'Resolving deltas: 100%'          "$BUILD_LOG" 2>/dev/null) || _git=0
            _done=$(( _apt + _npm + _pip_gem + _cargo + _git ))
            pct=$(( _done * 100 / _total_pkgs ))
            [ "$pct" -gt 99 ] && pct=99
        fi
        # Clamp to monotonic: never regress. If a tick underestimates (e.g.
        # regex races a partial log write), keep the last displayed value.
        [ "$pct" -lt "$_last_pct" ] && pct="$_last_pct"
        _last_pct="$pct"

        # Tail the last "[DOCKER]" lines — drop bare/empty entries, fold
        # "DONE Xs" / "CACHED" markers into the prior step, and dedupe
        # identical consecutive messages (BuildKit retries can repeat lines).
        local -a lines=()
        if [ -s "$BUILD_LOG" ]; then
            local ln c c_probe last_idx prev_c=""
            while IFS= read -r ln; do
                c="${ln#\[DOCKER\] }"
                [[ "$c" =~ ^#[0-9]+[[:space:]]+ ]] && c="${c#"${BASH_REMATCH[0]}"}"
                [[ "$c" =~ ^[0-9]+(\.[0-9]+)?[[:space:]]+ ]] && c="${c#"${BASH_REMATCH[0]}"}"
                c_probe="${c// /}"
                [ -z "$c_probe" ] && continue
                case "$c" in
                    DONE|DONE\ *|CACHED|CACHED\ *)
                        if [ "${#lines[@]}" -gt 0 ]; then
                            last_idx=$((${#lines[@]} - 1))
                            lines[$last_idx]="${lines[$last_idx]} — ${c}"
                            continue
                        fi
                        ;;
                esac
                [ "$c" = "$prev_c" ] && continue
                prev_c="$c"
                lines+=("$ln")
            done < <(tail -n 40 "$BUILD_LOG" 2>/dev/null)
            if [ "${#lines[@]}" -gt 6 ]; then
                lines=("${lines[@]: -6}")
            fi
        fi

        # Redraw 7 rows in place. Each row: \r\033[K<content>\n. After the 7th,
        # cursor sits one line below the block, so \033[7A rewinds to the top.
        printf "\r\033[K%b%s%b %s %b%d%%%b %b- Building Docker%b\n" \
            "$acc" "$mid" "$RESET" "$spin" "${C7:-}" "$pct" "$RESET" "${DIM:-}" "$RESET"
        local row
        for row in 0 1 2 3 4 5; do
            if [ "$row" -lt "${#lines[@]}" ]; then
                _docker_format_line "${lines[$row]}" "$cols"
                printf "\r\033[K  %s\n" "$_DOCKER_FMT"
            else
                printf "\r\033[K\n"
            fi
        done
        printf '\033[7A'

        sleep 0.15
        i=$((i + 1))
    done
    wait "$bg_pid"
    local rc=$?
    # Drop cursor past the block so post-build output starts on a fresh line.
    printf '\033[7B\r\033[?25h'
    trap - EXIT
    [ -n "$BUILD_LOG" ] && rm -f "$BUILD_LOG"
    [ "$LOG_MAX_BYTES" -ne 0 ] && _log_rotate_if_needed
    return "$rc"
}

# _tmux_nested_prompt — if USE_TMUX=true and the caller is already inside a
# host tmux session ($TMUX set), ask how to resolve the nesting. Mutates the
# caller's USE_TMUX (global) or exits. No-op in any other case.
_tmux_nested_prompt() {
    [ "${USE_TMUX:-false}" = "true" ] || return 0
    [ -n "${TMUX:-}" ]                || return 0

    echo
    echo "  You're already inside a tmux session on this host."
    echo "  How do you want to handle tmux for the container?"
    echo
    echo "    [1] keep using current (macOS) tmux — run the tool bare"
    echo "    [2] use docker's tmux — detach host tmux first (Ctrl+b d), then re-run"
    echo "    [3] tmux in tmux 🥴"
    echo
    local choice=""
    while :; do
        printf "  choose [1/2/3]: "
        read -r choice || exit 1
        case "$choice" in
            1) USE_TMUX=false; echo; return 0 ;;
            2) echo; echo "  Detach host tmux with Ctrl+b d, then re-run this command."; exit 0 ;;
            3) echo; return 0 ;;
        esac
    done
}

# _read_env_var KEY FILE — value of KEY= from FILE, strips surrounding quotes.
_read_env_var() {
    local KEY="$1" FILE="$2" VAL
    VAL="$(grep "^${KEY}=" "$FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
    case "$VAL" in
        \"*\"|\'*\') VAL="${VAL:1:${#VAL}-2}" ;;
    esac
    printf '%s' "$VAL"
}

# _validate_workspace_paths WORKSPACE_DIR DOCKER_DIR — 0 if safe to mount, 1 otherwise.
# Callers must only invoke when both args are non-empty (empty = mount disabled).
_validate_workspace_paths() {
    local WS="$1" DD="$2"

    # ── WORKSPACE_DIR (host side) ──────────────────────────────────────────
    # Exact-match denylist: paths too broad to safely bind-mount.
    # $HOME is compared so WORKSPACE_DIR=~ (already expanded by the caller
    # to the user's home) is caught.
    case "$WS" in
        "/"|"$HOME"|"/Users"|"/home"|"/etc"|"/var"|"/tmp"|"/private"|"/System"|"/Library"|"/Applications")
            printf "ERROR: WORKSPACE_DIR='%s' is too broad — refusing to bind-mount a system or home root.\n" "$WS" >&2
            printf "       Pick a project subfolder instead (e.g. %s/Projects).\n" "$HOME" >&2
            return 1
            ;;
    esac
    # Depth guard: require at least 3 non-empty path components
    # ($HOME alone → rejected; $HOME/Projects → ok).
    local stripped="${WS#/}"
    local slashes="${stripped//[^\/]/}"
    if [ "${#slashes}" -lt 2 ]; then
        printf "ERROR: WORKSPACE_DIR='%s' is too shallow — use a project subfolder (at least 3 path segments).\n" "$WS" >&2
        return 1
    fi

    # ── DOCKER_DIR (container side) ────────────────────────────────────────
    case "$DD" in
        /*) : ;;
        *)
            printf "ERROR: DOCKER_DIR='%s' must be an absolute path (start with /).\n" "$DD" >&2
            return 1
            ;;
    esac
    # Exact-match denylist of container system roots.
    case "$DD" in
        "/"|"/root"|"/etc"|"/bin"|"/sbin"|"/usr"|"/lib"|"/lib64"|"/var"|"/tmp"|"/proc"|"/sys"|"/dev"|"/home"|"/opt"|"/boot"|"/srv"|"/mnt"|"/media"|"/run")
            printf "ERROR: DOCKER_DIR='%s' collides with a container system path.\n" "$DD" >&2
            printf "       Pick something under /root (e.g. /root/Projects) or a fresh dir like /workspace.\n" >&2
            return 1
            ;;
    esac
    # Prefix denylist: anything underneath these roots is also dangerous.
    case "$DD" in
        /etc/*|/bin/*|/sbin/*|/usr/*|/lib/*|/lib64/*|/proc/*|/sys/*|/dev/*|/boot/*)
            printf "ERROR: DOCKER_DIR='%s' is under a container system path.\n" "$DD" >&2
            return 1
            ;;
    esac
    # /root is a valid parent, but three specific subpaths are taken by the
    # narrow Claude persistence mount — a clash there would shadow our binds.
    case "$DD" in
        /root/.claude|/root/.claude/*|/root/.config|/root/.config/*|/root/.claude.json)
            printf "ERROR: DOCKER_DIR='%s' collides with the Claude persistence mount.\n" "$DD" >&2
            printf "       Pick a different subpath under /root (e.g. /root/Projects).\n" >&2
            return 1
            ;;
    esac

    return 0
}

# _compute_cap_flags SANDBOX INTERNET SSH OUT_DROP OUT_ADD OUT_SEC
#   SANDBOX=true → --cap-drop ALL + NET_BIND_SERVICE + no-new-privileges.
#   INTERNET=false → + NET_ADMIN (iptables blocker needs it).
#   SSH=true → + SETGID + SETUID (sshd's privilege-separation fork calls
#              setgroups()/setuid(); without these caps the child aborts and
#              the client sees "Connection closed" right after KEXINIT).
_compute_cap_flags() {
    local sandbox="${1:-true}"
    local internet="${2:-true}"
    local ssh="${3:-false}"
    local out_drop="${4:-CAP_DROP}"
    local out_add="${5:-CAP_ADD}"
    local out_sec="${6:-SECURITY_OPT}"

    local cap_drop="" cap_add="" sec_opt=""

    if [ "$sandbox" != "false" ]; then
        cap_drop="--cap-drop ALL"
        cap_add="--cap-add NET_BIND_SERVICE"
        sec_opt="--security-opt no-new-privileges:true"
    fi
    if [ "$internet" = "false" ]; then
        cap_add="${cap_add:+$cap_add }--cap-add NET_ADMIN"
    fi
    if [ "$ssh" = "true" ]; then
        cap_add="${cap_add:+$cap_add }--cap-add SETGID --cap-add SETUID"
    fi

    printf -v "$out_drop" '%s' "$cap_drop"
    printf -v "$out_add"  '%s' "$cap_add"
    printf -v "$out_sec"  '%s' "$sec_opt"
}

setup_dirs() {
    # Pre-create bind-mount targets so Docker doesn't root-own them on the host.
    mkdir -p "$HOME/.llm-docker/claude/.claude"
    mkdir -p "$HOME/.llm-docker/claude/.config"
    mkdir -p "$HOME/.llm-docker/opencode/.config/opencode"
    mkdir -p "$HOME/.llm-docker/opencode/.local/share/opencode"
    mkdir -p "$HOME/.llm-docker/opencode/.cache/opencode"
    # SSH host-key persistence. First run leaves it empty — setup-ssh.sh
    # generates keys inside the container on the mount, so the fingerprint
    # survives rebuilds.
    mkdir -p "$HOME/.llm-docker/ssh"
    chmod 700 "$HOME/.llm-docker/ssh"
    # .claude.json is bind-mounted as a FILE; pre-touch or Docker creates a dir.
    [ -e "$HOME/.llm-docker/claude/.claude.json" ] || \
        touch "$HOME/.llm-docker/claude/.claude.json"
    _log SETUP "Data directories ready"
}

setup_env() {
    # llm-docker.conf is committed; .env is gitignored and seeded here.
    # Skip when env-gorilla (KeePassXC) is injecting secrets — those users
    # intentionally run without a .env and a seeded file just gets in the way.
    if [ -n "${LLM_DOCKER_ENV_GORILLA:-}" ]; then
        return 0
    fi
    if [ ! -f "$SCRIPT_DIR/.env" ]; then
        _log SETUP "Creating .env from template..."
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        _log SETUP "Edit $SCRIPT_DIR/.env to add your API keys"
    fi
}

# Source llm-docker.conf then .env — .env wins on conflicts.
#
# NOTE: we parse line-by-line instead of `source <(sed 's/^/export /')` because
# unquoted values containing spaces (e.g. a raw `ssh-rsa AAAA... user@host`
# public key in .env) used to be handed to bash as a multi-arg `export`, which
# blows up on the key's `/` chars with "not a valid identifier" and, combined
# with cld's `set -e`, silently aborts the launcher halfway — resulting in a
# container started without the SSH `-p` bridge flags. `docker --env-file`
# parses the same files correctly on its own, so the container still sees
# the full values.
_source_all_config() {
    local f line key val
    for f in "$SCRIPT_DIR/llm-docker.conf" "$SCRIPT_DIR/.env"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip blanks and comments.
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            # Must contain '=' and a valid shell identifier on the left.
            [[ "$line" != *=* ]] && continue
            key="${line%%=*}"
            val="${line#*=}"
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            # Strip one layer of surrounding single or double quotes.
            if [[ "$val" == \"*\" ]]; then val="${val#\"}"; val="${val%\"}"
            elif [[ "$val" == \'*\' ]]; then val="${val#\'}"; val="${val%\'}"
            fi
            # Expand leading tilde to $HOME (matches bash assignment behavior).
            [[ "$val" == "~" || "$val" == "~/"* ]] && val="${HOME}${val:1}"
            export "$key=$val"
        done < "$f"
    done
}

# _llm-docker_image_for_tool TOOL — prints which image tag cld/ocd should
# use for the given tool (claude|opencode|both). Resolution order:
#   1. llm-docker-$TOOL:latest (tool-specific, if present)
#   2. llm-docker:latest       (combined image from install.sh, if present)
#   3. llm-docker-$TOOL:latest (default build target when nothing exists)
# "both" always resolves to llm-docker:latest.
_llm-docker_image_for_tool() {
    local tool="${1:-both}"
    if [ "$tool" = "both" ]; then
        printf '%s' "llm-docker:latest"
        return 0
    fi
    if docker image inspect "llm-docker-${tool}:latest" >/dev/null 2>&1; then
        printf '%s' "llm-docker-${tool}:latest"
    elif docker image inspect "llm-docker:latest" >/dev/null 2>&1; then
        printf '%s' "llm-docker:latest"
    else
        printf '%s' "llm-docker-${tool}:latest"
    fi
}

setup_image() {
    # setup_image [TOOL] [--no-cache]
    #   TOOL = claude | opencode | both (default: both)
    # Tool-specific builds tag llm-docker-$TOOL:latest and only install that
    # CLI (see ARG TOOL in Dockerfile). "both" builds the combined image
    # (llm-docker:latest) — this is what install.sh uses.
    # After flipping INSTALL_* flags in llm-docker.conf, `docker rmi` the
    # relevant tag to force a rebuild.
    local tool="both"
    local build_args=()
    local force_rebuild=false

    while [ $# -gt 0 ]; do
        case "$1" in
            claude|opencode|both) tool="$1"; shift ;;
            --no-cache) force_rebuild=true; build_args+=(--no-cache); shift ;;
            *) shift ;;
        esac
    done

    local tag
    tag="$(_llm-docker_image_for_tool "$tool")"

    if [ "$force_rebuild" = false ] && docker image inspect "$tag" >/dev/null 2>&1; then
        _log_silent SETUP "Docker image $tag already built — skipping build"
        return 0
    fi

    # Build target tag = tool-specific for claude/opencode, llm-docker:latest for both.
    local build_tag="llm-docker:latest"
    [ "$tool" != "both" ] && build_tag="llm-docker-${tool}:latest"

    _log SETUP "Building Docker image $build_tag. For details run: tail logs/llm-docker.log"
    _log_docker_exec docker build "${build_args[@]}" \
        --build-arg "TOOL=${tool}" \
        -t "$build_tag" "$SCRIPT_DIR"
}

# setup_image_incremental [TOOL] — smart rebuild that re-runs install_cli.sh
# and install_devpack.sh INSIDE an existing image, then `docker commit`s the
# result. Skips the heavy stuff that's already installed (Go binaries, cargo
# crates, ferox/nikto/codeman, npm globals) thanks to the idempotency guards
# in those scripts. Falls back to a full `setup_image` if the image is missing
# or the in-place run fails.
#
# Trade-off vs `setup_image`: layered commits accumulate cruft over many smart
# rebuilds (removed packages don't free disk). Periodically run --rebuild-force
# (cld/ocd) to start fresh.
setup_image_incremental() {
    local tool="${1:-both}"
    local build_tag="llm-docker:latest"
    [ "$tool" != "both" ] && build_tag="llm-docker-${tool}:latest"

    if ! docker image inspect "$build_tag" >/dev/null 2>&1; then
        _log SETUP "No existing $build_tag — falling back to full build."
        setup_image "$tool"
        return $?
    fi

    _log SETUP "Smart rebuild: updating $build_tag in place (skip-if-installed)."
    _log SETUP "For details run: tail logs/llm-docker.log"

    local container="llm-docker-update-$$"
    _log_ensure_dir
    # Best-effort cleanup if anything left behind.
    docker rm -f "$container" >/dev/null 2>&1 || true

    if ! docker run -d --name "$container" \
            --entrypoint sleep \
            -v "$SCRIPT_DIR:/build:ro" \
            "$build_tag" 1800 >/dev/null 2>&1; then
        _log SETUP ERROR "Failed to start update container — falling back to full build."
        setup_image "$tool"
        return $?
    fi

    # Run the install scripts inside the container, sourcing the latest
    # llm-docker.conf so updated INSTALL_* flags take effect. tee the live
    # output through _log_docker_exec's spinner just like a real build.
    if ! _log_docker_exec docker exec "$container" bash -c "
        set -e
        cp /build/llm-docker.conf /tmp/llm-docker.conf
        cp /build/docker/install_cli.sh /tmp/install_cli.sh
        cp /build/docker/install_devpack.sh /tmp/install_devpack.sh
        chmod +x /tmp/install_cli.sh /tmp/install_devpack.sh
        set -a; . /tmp/llm-docker.conf; set +a
        /tmp/install_cli.sh '$tool'
        /tmp/install_devpack.sh
        rm -f /tmp/llm-docker.conf /tmp/install_cli.sh /tmp/install_devpack.sh
    "; then
        _log SETUP ERROR "Smart rebuild failed; image left as-is."
        docker rm -f "$container" >/dev/null 2>&1 || true
        return 1
    fi

    # Commit in place. The container was started with `--entrypoint sleep`,
    # and docker commit inherits that override into the new image — so we
    # MUST restore the original ENTRYPOINT (and clear the stray `1800` CMD)
    # via --change, otherwise the next `cld`/`ocd` launch runs `sleep <args>`
    # and dies with `sleep: invalid time interval '<INIT_PROMPT>'`.
    if ! docker commit \
            --change 'ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]' \
            --change 'CMD []' \
            "$container" "$build_tag" >/dev/null; then
        _log SETUP ERROR "docker commit failed; image left as-is."
        docker rm -f "$container" >/dev/null 2>&1 || true
        return 1
    fi

    docker rm -f "$container" >/dev/null 2>&1 || true
    _log SETUP "Smart rebuild complete: $build_tag updated."
    return 0
}

# Run all setup steps. Called from cld/ocd at launch for first-time-ish
# bootstrap (missing dirs, missing image). `.env` is intentionally NOT checked
# here — it's user-managed and may legitimately be absent (e.g. when secrets
# come from env-gorilla / KeePassXC). install.sh handles initial .env seeding
# as its own explicit wizard step; cld/ocd never regenerate .env on launch.
run_setup() {
    # run_setup [TOOL] — TOOL = claude | opencode | both (default: both).
    # Tool-specific invocations only build llm-docker-<tool>:latest if
    # neither that nor the combined llm-docker:latest image exists.
    local tool="${1:-both}"
    local NEEDS_SETUP=false

    # Seed .env from template even when the rest of setup is satisfied —
    # users who skipped install.sh (fresh clone → cld directly) still need
    # a .env for `--env-file` to load. Idempotent.
    setup_env

    # Check what's missing — list each narrow-mount target so an upgrade from
    # an older (broad-mount) install triggers setup_dirs to create them.
    [ ! -d "$HOME/.llm-docker/claude/.claude" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/claude/.config" ] && NEEDS_SETUP=true
    [ ! -e "$HOME/.llm-docker/claude/.claude.json" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/opencode/.config/opencode" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/opencode/.local/share/opencode" ] && NEEDS_SETUP=true
    [ ! -d "$HOME/.llm-docker/opencode/.cache/opencode" ] && NEEDS_SETUP=true
    [ ! -f "$SCRIPT_DIR/llm-docker.conf" ] && NEEDS_SETUP=true

    # Image check: either the tool-specific image OR the combined one is fine.
    if [ "$tool" = "both" ]; then
        docker image inspect llm-docker:latest >/dev/null 2>&1 || NEEDS_SETUP=true
    else
        if ! docker image inspect "llm-docker-${tool}:latest" >/dev/null 2>&1 \
           && ! docker image inspect llm-docker:latest >/dev/null 2>&1; then
            NEEDS_SETUP=true
        fi
    fi

    if [ "$NEEDS_SETUP" = false ]; then
        return 0
    fi

    # If persistent dirs already exist, the user has run llm-docker before —
    # we're rebuilding a missing image, not setting up from scratch.
    local _subtitle="first-time setup"
    if [ -d "$HOME/.llm-docker/claude/.claude" ] \
    || [ -d "$HOME/.llm-docker/opencode/.local/share/opencode" ]; then
        _subtitle="re-building"
    fi

    print_banner "$_subtitle"
    setup_dirs
    setup_image "$tool"
    echo ""
    echo "Setup complete."
    echo ""
}

# Allow running directly: ./setup.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_setup
fi
