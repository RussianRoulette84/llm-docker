# setup/config.sh — module of the split setup.sh (sourced by the setup.sh loader).

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
