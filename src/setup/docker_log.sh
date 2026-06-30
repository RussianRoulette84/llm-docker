# setup/docker_log.sh — module of the split setup.sh (sourced by the setup.sh loader).

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
    [ -n "$BUILD_LOG" ] && /bin/rm -f "$BUILD_LOG"
    [ "$LOG_MAX_BYTES" -ne 0 ] && _log_rotate_if_needed
    return "$rc"
}

# _tmux_nested_prompt — if USE_TMUX=true and the caller is already inside a
# host tmux session ($TMUX set), ask how to resolve the nesting. Mutates the
