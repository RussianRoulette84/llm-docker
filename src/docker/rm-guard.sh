#!/bin/bash
# rm-guard.sh — a safe `rm` replacement installed at /usr/local/bin/rm so EVERY
# tool in the container (Claude, OpenCode, raw scripts, python wrappers) gets a
# delete that can't wipe the host through a bind-mount.
#
# Policy (in order, per target path):
#   1. PROTECTED  → refuse outright (exit 1). The mount roots and their
#                   ancestors — deleting them (or recursing into them) would
#                   destroy host data: `/`, `$HOME`, DOCKER_DIR (/root/Projects),
#                   any bind-mount point, any ancestor of a bind-mount, and the
#                   Claude/OpenCode persistence mounts.
#   2. EPHEMERAL  → real removal. /tmp, /var/tmp, and other non-/root scratch —
#                   trashing these would just litter and slow tooling.
#   3. EVERYTHING ELSE → TRASH, never destroy. If the builder-api is reachable
#                   and the path is inside the writable project, route to the
#                   HOST trash job (recoverable in the Mac Trash, audited).
#                   Otherwise fall back to the container's `trash` (trash-cli).
#
# This is defense-in-depth and recoverability. The HARD guarantee is the
# read-only workspace mount (an agent literally can't write the protected
# paths); this shim makes the writable project recoverable and stops the
# obvious `rm -rf /root/Projects` foot-gun for non-Claude tools too.

set -u

REAL_RM="/bin/rm"
TRASH_BIN="$(command -v trash-put || command -v trash || true)"
DOCKER_DIR="${DOCKER_DIR:-/root/Projects}"

# Absolute, symlink/.. normalized path WITHOUT requiring existence.
_norm() { readlink -m -- "$1" 2>/dev/null || printf '%s' "$1"; }

# Bind-mount points under /root (the project, the ro workspace, persistence).
# These + their ancestors are the no-delete set.
_mount_points() { awk '$2 ~ /^\/root(\/|$)/ {print $2}' /proc/mounts 2>/dev/null; }

_is_protected() {
    local p; p="$(_norm "$1")"
    case "$p" in
        /|/root|"$HOME"|"$DOCKER_DIR"|/root/.claude|/root/.config|/root/.claude.json) return 0 ;;
        /bin|/sbin|/usr|/lib|/lib64|/etc|/var|/boot|/sys|/proc|/dev) return 0 ;;
    esac
    local mp
    while IFS= read -r mp; do
        [ -z "$mp" ] && continue
        # target IS a mount point, or target is an ANCESTOR of one (rm -rf would
        # recurse into the mount and delete host files).
        [ "$p" = "$mp" ] && return 0
        case "$mp" in "$p"/*) return 0 ;; esac
    done < <(_mount_points)
    return 1
}

_is_ephemeral() {
    local p; p="$(_norm "$1")"
    case "$p" in
        /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm/*|/run/*) return 0 ;;
    esac
    # Anything NOT under /root is treated as system/ephemeral (real rm) — user
    # data lives under the /root mounts.
    case "$p" in /root|/root/*) return 1 ;; *) return 0 ;; esac
}

# Try the host-side trash job via builder-api. Returns 0 on success.
_api_trash() {
    local p; p="$(_norm "$1")"
    [ -n "${BUILDER_API_PASSWORD:-}" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    # Only for paths inside the writable project mount.
    case "$p" in "$DOCKER_DIR"/*) : ;; *) return 1 ;; esac
    # Path relative to the project mount root ($DOCKER_DIR/<token>/...).
    local under="${p#$DOCKER_DIR/}"; local token="${under%%/*}"; local rel="${under#*/}"
    [ "$rel" = "$under" ] && rel=""          # path WAS the project root itself
    [ -z "$rel" ] && return 1                 # never trash a whole project via API
    local host="${BUILDER_API_HOST:-host.docker.internal}" port="${BUILDER_API_PORT:-6666}"
    curl -fsS -m 8 -X POST \
        -H "X-Builder-API-Password: $BUILDER_API_PASSWORD" \
        -H 'Content-Type: application/json' \
        --data "$(printf '{"params":{"path":"%s"},"agent_id":"rm-guard"}' "$rel")" \
        "http://$host:$port/job/trash" >/dev/null 2>&1
}

_trash_one() {
    local target="$1"
    if _api_trash "$target"; then return 0; fi
    if [ -n "$TRASH_BIN" ]; then "$TRASH_BIN" -- "$target" 2>/dev/null && return 0; fi
    printf 'rm-guard: refusing to permanently delete %s (no trash available)\n' "$target" >&2
    return 1
}

# ── parse argv: separate options from path operands ────────────────────────
opts=(); targets=(); end_opts=false
for a in "$@"; do
    if [ "$end_opts" = false ]; then
        case "$a" in
            --) end_opts=true; continue ;;
            -*) opts+=("$a"); continue ;;
        esac
    fi
    targets+=("$a")
done

[ ${#targets[@]} -eq 0 ] && exit 0   # `rm` with no operands → nothing to do

rc=0
for t in "${targets[@]}"; do
    if _is_protected "$t"; then
        printf '\033[31mrm-guard: REFUSED — %s is a protected mount root. Deleting it would wipe host data.\033[0m\n' "$t" >&2
        rc=1
        continue
    fi
    if _is_ephemeral "$t"; then
        "$REAL_RM" "${opts[@]}" -- "$t" || rc=$?
        continue
    fi
    _trash_one "$t" || rc=1
done
exit "$rc"
