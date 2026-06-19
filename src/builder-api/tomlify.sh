#!/usr/bin/env bash
# tomlify.sh — install the LLM-docker API config from the repo to the host.
#
# Lives at src/builder-api/tomlify.sh next to the daemon's other files. Every
# config file lives under a single directory now:
#   <repo>/api_config/builder-api.toml   → ~/.llm-docker/api_config/builder-api.toml
#   <repo>/api_config/<name>.toml        → ~/.llm-docker/api_config/<name>.toml
#
# Usage (from any cwd; absolute paths are resolved from $BASH_SOURCE):
#   src/builder-api/tomlify.sh <project-name>   Install one shard
#   src/builder-api/tomlify.sh base             Install the base host config
#   src/builder-api/tomlify.sh all              Base + every shard (default)
#   src/builder-api/tomlify.sh list             Show available shards
#
# Uses `install -m 0644` so overwrites are non-interactive (no `cp -i` prompt)
# and the resulting host file ends up owner-write / world-read.
#
# Daemon does NOT hot-reload (intentional — security boundary). Restart with
# cld / ocd from any project when you're ready.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_API_CONFIG="$REPO_ROOT/api_config"
REPO_BASE="$REPO_API_CONFIG/builder-api.toml"
HOST_API_CONFIG="$HOME/.llm-docker/api_config"
HOST_BASE="$HOST_API_CONFIG/builder-api.toml"
# Project shards = every *.toml in api_config/ EXCEPT the base file. Used
# everywhere we iterate; keep the filter in one place.
_shard_name() { basename "$1" .toml; }
_is_base() { [ "$(_shard_name "$1")" = "builder-api" ]; }

# ANSI palette (NO_COLOR opt-out per the project rules). Blue gradient
# matches cld/install.sh's banner so the LLM-DOCKER ascii reads the same
# whether you're installing the cage itself or just refreshing the host
# config through this script.
if [ -z "${NO_COLOR:-}" ]; then
    P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'; D=$'\033[2m'; RST=$'\033[0m'
    B1=$'\033[38;5;33m'; B2=$'\033[38;5;39m'; B3=$'\033[38;5;45m'
    B4=$'\033[38;5;51m'; B5=$'\033[38;5;81m'
else
    P=; G=; R=; D=; RST=
    B1=; B2=; B3=; B4=; B5=
fi

# Print the blue LLM-DOCKER banner from src/ascii/llm-docker.txt, one
# color per row in the cage-wide blue gradient. Silently skips when the
# ascii file is missing so a stripped-down checkout still installs.
print_banner() {
    local ascii="$REPO_ROOT/src/ascii/llm-docker.txt"
    [ -f "$ascii" ] || return 0
    local i=0 line
    local colors=("$B1" "$B2" "$B3" "$B4" "$B5")
    printf '\n'
    while IFS= read -r line; do
        printf '  %s%s%s\n' "${colors[$((i % ${#colors[@]}))]}" "$line" "$RST"
        i=$((i + 1))
    done < "$ascii"
    printf '\n'
}

print_banner

usage() {
    cat >&2 <<EOF
Usage: $0 <project-name>
       $0 base
       $0 all
       $0 list

Examples:
  $0 purpletech      Install just the purpletech shard
  $0 base            Install the base host config
  $0 all             Install base + every shard
  $0 list            Show available shards

After install: cld -c -a (the daemon doesn't hot-reload).
EOF
    exit 1
}

# No-arg form: install everything. Friendliest default so `tomlify.sh` alone
# isn't a usage dead-end. `tomlify.sh help` (or -h/--help) still prints usage.
if [ $# -eq 0 ]; then
    set -- all
fi
[ $# -eq 1 ] || usage

install_base() {
    [ -f "$REPO_BASE" ] || {
        echo "${R}🛑 base not found: $REPO_BASE${RST}" >&2
        return 1
    }
    mkdir -p "$HOST_API_CONFIG"
    install -m 0644 "$REPO_BASE" "$HOST_BASE"
    echo "${G}✓ base → $HOST_BASE${RST}"
}

install_shard() {
    local name="$1"
    local src="$REPO_API_CONFIG/$name.toml"
    if [ "$name" = "builder-api" ]; then
        echo "${R}🛑 use 'base' to install builder-api.toml, not the shard form${RST}" >&2
        return 1
    fi
    if [ ! -f "$src" ]; then
        echo "${R}🛑 no shard at $src${RST}" >&2
        if [ -d "$REPO_API_CONFIG" ]; then
            local avail
            avail=$(ls "$REPO_API_CONFIG"/*.toml 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.toml$//' | grep -v '^builder-api$')
            [ -n "$avail" ] && echo "${D}available: $avail${RST}" >&2
        fi
        return 1
    fi
    mkdir -p "$HOST_API_CONFIG"
    install -m 0644 "$src" "$HOST_API_CONFIG/$name.toml"
    echo "${G}✓ $name → $HOST_API_CONFIG/$name.toml${RST}"
}

case "$1" in
    list)
        echo "${P}base:${RST} $REPO_BASE"
        echo "${P}shards:${RST}"
        for f in "$REPO_API_CONFIG"/*.toml; do
            [ -f "$f" ] || continue
            _is_base "$f" && continue
            echo "  $(_shard_name "$f")"
        done
        exit 0
        ;;
    base)
        install_base
        ;;
    all)
        install_base
        for f in "$REPO_API_CONFIG"/*.toml; do
            [ -f "$f" ] || continue
            _is_base "$f" && continue
            install_shard "$(_shard_name "$f")"
        done
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        install_shard "$1"
        ;;
esac

echo "${D}Restart daemon with: cld -c -a${RST}"
