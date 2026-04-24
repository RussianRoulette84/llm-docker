#!/usr/bin/env bash
# install_test.sh — post-install health check for llm-docker.
# Requires bash 4+; macOS `/bin/bash` is 3.2, so use env to find homebrew bash.
# Spins up a throwaway container with the same mounts cld uses, probes it,
# and prints a categorized report (base, SECURITY, RUBY, CPP, LLVM_CLANG,
# NS, MEDIA, sandbox, sshd, net, templates, persistence, image).
#
# Usage:  ./src/install_test.sh
# Exit:   0 = all green / skipped groups OK; 1 = image missing or probe failed.

set -u

SCRIPT_DIR="$( cd "$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )" && pwd )"

RESET=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
PURPLE=$'\033[38;5;177m'; BLUE=$'\033[38;5;39m'

_header() { printf "\n${PURPLE}◆ %s${RESET}\n" "$1"; }
_skipped(){ printf "\n${PURPLE}◇ %s ${DIM}(disabled — skipping)${RESET}\n" "$1"; }
_ok()     { printf "  ${GREEN}✔${RESET} %-16s ${DIM}%s${RESET}\n" "$1" "$2"; }
_absent() { printf "  ${DIM}○ %-16s (absent)${RESET}\n" "$1"; }
_warn()   { printf "  ${YELLOW}!${RESET} %-16s ${DIM}%s${RESET}\n" "$1" "$2"; }
_fail()   { printf "  ${RED}✗${RESET} %-16s ${DIM}%s${RESET}\n" "$1" "$2"; }

if [ ! -f "$SCRIPT_DIR/llm-docker.conf" ]; then
    echo "${RED}llm-docker.conf not found — run install.sh first.${RESET}" >&2
    exit 1
fi
if ! docker image inspect llm-docker:latest >/dev/null 2>&1; then
    echo "${RED}llm-docker:latest image missing — run install.sh first.${RESET}" >&2
    exit 1
fi

_read_conf() { grep "^$1=" "$SCRIPT_DIR/llm-docker.conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
INSTALL_SECURITY=$(_read_conf INSTALL_SECURITY)
INSTALL_RUBY=$(_read_conf INSTALL_RUBY)
INSTALL_CPP=$(_read_conf INSTALL_CPP)
INSTALL_LLVM_CLANG=$(_read_conf INSTALL_LLVM_CLANG)
INSTALL_NS=$(_read_conf INSTALL_NS)
INSTALL_MEDIA=$(_read_conf INSTALL_MEDIA)

printf "\n${BOLD}${PURPLE}llm-docker · post-install health check${RESET}\n"
printf "${DIM}────────────────────────────────────────────────${RESET}\n"

# ── Host-side: image metadata + persistence ─────────────────────────────────
_header "Image"
IMG_CREATED=$(docker image inspect llm-docker:latest --format '{{.Created}}' 2>/dev/null)
IMG_SIZE=$(docker image inspect llm-docker:latest --format '{{.Size}}' 2>/dev/null)
_ok "llm-docker:latest" "built $IMG_CREATED · $(( IMG_SIZE / 1024 / 1024 )) MB"

_header "Persistence (host ~/.llm-docker)"
for p in \
    "$HOME/.llm-docker/claude/.claude" \
    "$HOME/.llm-docker/claude/.claude.json" \
    "$HOME/.llm-docker/claude/.config" \
    "$HOME/.llm-docker/opencode/.config/opencode" \
    "$HOME/.llm-docker/opencode/.local/share/opencode" \
    "$HOME/.llm-docker/opencode/.cache/opencode"; do
    if [ -e "$p" ]; then
        sz=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
        _ok "$(basename "$p")" "$sz  $p"
    else
        _warn "$(basename "$p")" "missing ($p)"
    fi
done
if [ -f "$HOME/.llm-docker/claude/.claude/.credentials.json" ]; then
    _ok "OAuth token" "present — first launch skips /login"
else
    _warn "OAuth token" "none — first launch will prompt /login"
fi

# ── Container probe ──────────────────────────────────────────────────────────
# Heredoc: single-quoted EOF so $vars are evaluated INSIDE the container.
PROBE=$(cat <<'PROBE_EOF'
set -u
_v() {
    case "$1" in
        claude)       claude --version 2>/dev/null | awk '{print $1}' ;;
        opencode)     opencode --version 2>/dev/null | head -1 ;;
        node)         node -v 2>/dev/null ;;
        npm)          npm -v 2>/dev/null ;;
        pnpm)         pnpm -v 2>/dev/null ;;
        uv)           uv --version 2>/dev/null | awk '{print $2}' ;;
        git)          git --version 2>/dev/null | awk '{print $3}' ;;
        python3)      python3 --version 2>/dev/null | awk '{print $2}' ;;
        jq)           jq --version 2>/dev/null ;;
        sqlite3)      sqlite3 -version 2>/dev/null | awk '{print $1}' ;;
        tmux)         tmux -V 2>/dev/null | awk '{print $2}' ;;
        trash)        trash --version 2>/dev/null | head -1 | awk '{print $NF}' ;;
        nmap)         nmap -V 2>/dev/null | head -1 | awk '{print $3}' ;;
        nikto)        nikto -Version 2>/dev/null | head -1 | awk '{print $NF}' ;;
        sqlmap)       sqlmap --version 2>/dev/null | head -1 ;;
        gobuster)     gobuster version 2>/dev/null | head -1 ;;
        amass)        amass -version 2>&1 | head -1 | awk '{print $NF}' ;;
        ffuf)         ffuf -V 2>&1 | awk '/ffuf/{print $2; exit}' ;;
        httpx)        httpx -version 2>&1 | awk '/Current/ {print $NF}' ;;
        nuclei)       nuclei -version 2>&1 | awk '/Current/ {print $NF}' ;;
        subfinder)    subfinder -version 2>&1 | awk '/Current/ {print $NF}' ;;
        trufflehog)   trufflehog --version 2>&1 | awk '{print $NF; exit}' ;;
        feroxbuster)  feroxbuster --version 2>/dev/null | awk '{print $2; exit}' ;;
        go)           go version 2>/dev/null | awk '{print $3}' ;;
        rbenv)        rbenv --version 2>/dev/null | awk '{print $2}' ;;
        ruby)         ruby --version 2>/dev/null | awk '{print $2}' ;;
        pod)          pod --version 2>/dev/null ;;
        make)         make --version 2>/dev/null | head -1 | awk '{print $3}' ;;
        cmake)        cmake --version 2>/dev/null | head -1 | awk '{print $3}' ;;
        gcc)          gcc --version 2>/dev/null | head -1 | awk '{print $NF}' ;;
        g++)          g++ --version 2>/dev/null | head -1 | awk '{print $NF}' ;;
        clang)        clang --version 2>/dev/null | head -1 | awk '{print $3}' ;;
        clang-format) clang-format --version 2>/dev/null | awk '{print $NF}' ;;
        n)            n --version 2>/dev/null ;;
        tns)          tns --version 2>/dev/null ;;
        ns)           ns --version 2>/dev/null ;;
        ffmpeg)       ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}' ;;
        sox)          sox --version 2>/dev/null | awk '{print $3}' ;;
        yt-dlp)       yt-dlp --version 2>/dev/null ;;
        pipx)         pipx --version 2>/dev/null ;;
    esac
}
_row() {
    local t="$1" p v
    p=$(command -v "$t" 2>/dev/null || true)
    if [ -n "$p" ]; then v="$(_v "$t")"; printf "%s|%s|%s\n" "$t" "$p" "${v:-?}"
    else printf "%s|ABSENT|\n" "$t"; fi
}

echo "== mounts =="
mount | awk '/\/root|\/etc\/ssh|\/opt\/llm-docker|\/usr\/local\/bin\/docker-entrypoint/ {print $3}' | sort -u

echo "== base =="
for t in claude opencode node npm pnpm uv git python3 jq sqlite3 tmux trash; do _row "$t"; done
echo "== SECURITY =="
for t in nmap nikto sqlmap gobuster amass ffuf httpx nuclei subfinder trufflehog feroxbuster go; do _row "$t"; done
echo "== RUBY =="
for t in rbenv ruby pod; do _row "$t"; done
echo "== CPP =="
for t in make cmake gcc; do _row "$t"; done
echo "== LLVM_CLANG =="
for t in clang clang-format g++; do _row "$t"; done
echo "== NS =="
for t in n tns ns; do _row "$t"; done
echo "== MEDIA =="
for t in ffmpeg sox yt-dlp pipx; do _row "$t"; done

echo "== sandbox =="
grep NoNewPrivs /proc/self/status 2>/dev/null | tr -d '\t'
echo "== net =="
curl -sS -o /dev/null -w 'anthropic=%{http_code} dns=%{time_namelookup}s total=%{time_total}s' --max-time 5 https://api.anthropic.com/ 2>&1 | head -1
echo ""
echo "== templates =="
ls /opt/llm-docker/templates/ 2>/dev/null
echo "== image =="
cat /IMAGE_BUILD_DATE 2>/dev/null
PROBE_EOF
)

OUT=$(docker run --rm -i \
    -v "$HOME/.llm-docker/claude/.claude:/root/.claude" \
    -v "$HOME/.llm-docker/claude/.config:/root/.config" \
    -v "$HOME/.llm-docker/claude/.claude.json:/root/.claude.json" \
    -v "$SCRIPT_DIR/docker/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro" \
    -v "$SCRIPT_DIR/llm-container-claude-settings.json:/opt/llm-docker/templates/claude-settings.json:ro" \
    --entrypoint bash \
    llm-docker:latest -s <<< "$PROBE" 2>&1) || { echo "${RED}Probe failed:${RESET}"; echo "$OUT"; exit 1; }

_section() { awk -v s="== $1 ==" 'start && /^== / {exit} $0 ~ s {start=1; next} start' <<< "$OUT"; }

_render_tool_block() {
    _section "$1" | while IFS='|' read -r name path ver; do
        [ -z "$name" ] && continue
        if [ "$path" = "ABSENT" ]; then _absent "$name"
        else _ok "$name" "$ver  $path"; fi
    done
}
_render_group() {
    local label="$1" section="$2" enabled="$3"
    if [ "$enabled" = "true" ]; then
        _header "$label"; _render_tool_block "$section"
    else
        _skipped "$label"
    fi
}

# Container mounts
_header "Container mounts"
while read -r m; do [ -n "$m" ] && _ok "$(basename "$m")" "$m"; done < <(_section mounts)

# Always-on
_header "Base"
_render_tool_block "base"

# Devpacks (gated by conf)
_render_group "SECURITY"   "SECURITY"   "$INSTALL_SECURITY"
_render_group "RUBY"       "RUBY"       "$INSTALL_RUBY"
_render_group "CPP"        "CPP"        "$INSTALL_CPP"
_render_group "LLVM_CLANG" "LLVM_CLANG" "$INSTALL_LLVM_CLANG"
_render_group "NS"         "NS"         "$INSTALL_NS"
_render_group "MEDIA"      "MEDIA"      "$INSTALL_MEDIA"

# Sandbox
_header "Sandbox"
SBOX=$(_section sandbox | head -1)
if [ -n "$SBOX" ]; then _ok "no-new-privs" "$SBOX"; else _warn "no-new-privs" "could not read /proc"; fi

# sshd — skipped in the install_test probe because this container bypasses
# the entrypoint (no /setup-ssh.sh run). Use ./src/smoke_test.sh for the
# real end-to-end SSH check.

# Network
_header "Network"
NET=$(_section net | head -1)
case "$NET" in
    *anthropic=2*|*anthropic=4*) _ok "anthropic" "$NET" ;;
    *) _warn "anthropic" "$NET" ;;
esac

# Templates
_header "Templates"
while read -r t; do
    [ -n "$t" ] && _ok "$t" "/opt/llm-docker/templates/$t"
done < <(_section templates)

# Image
_header "Image timestamp"
BD=$(_section image | head -1)
_ok "IMAGE_BUILD_DATE" "$BD"

printf "\n${GREEN}Health check complete.${RESET}\n"
