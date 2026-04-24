#!/bin/bash
# install_devpack.sh — optional software groups, controlled by INSTALL_*
# environment variables. Called from the Dockerfile during image build,
# reading ARG → ENV values that originate in src/llm-docker.conf.
#
# Target platform: node:24 (Debian bookworm). Anything that doesn't cleanly
# install from apt falls back to go/npm/pip/prebuilt-binary.
#
# Groups (each toggled by an INSTALL_* var; default: false):
#   INSTALL_SECURITY    — pen-testing + audit tools
#   INSTALL_RUBY        — rbenv + ruby-build (+ cocoapods via gem)
#   INSTALL_CPP         — make + cmake + gcc
#   INSTALL_LLVM_CLANG  — CPP + g++ + clang + clang-format + clang-tools
#   INSTALL_NS          — NativeScript CLI + node version manager (n)
#   INSTALL_MEDIA       — ffmpeg + sox + yt-dlp + pipx
#   INSTALL_QUAKE       — full C/C++ toolchain + SDL2 (for the Quake port)
#
# Inspired by the macOS `devpack` script — same array-of-packages idea,
# adapted to Linux/apt.

set -e

# ── Package arrays per group ────────────────────────────────────────
# nikto + amass are not packaged for Debian bookworm (nikto: dropped; amass:
# orphaned). Installed below via git + go. libwww-perl / libnet-ssleay-perl
# are nikto's runtime deps.
SW_SECURITY_APT=(nmap sqlmap chkrootkit rkhunter lynis gobuster ffuf libwww-perl libnet-ssleay-perl)
SW_SECURITY_GO=(
    "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    "github.com/trufflesecurity/trufflehog/v3@latest"
    "github.com/owasp-amass/amass/v4/...@master"
)
SW_SECURITY_NIKTO_REPO="https://github.com/sullo/nikto"
SW_SECURITY_FEROX_URL="https://github.com/epi052/feroxbuster/releases/latest/download/x86_64-linux-feroxbuster.tar.gz"

SW_RUBY_APT=(rbenv ruby-build ruby-dev libffi-dev)
SW_RUBY_GEM=(cocoapods)

SW_CPP_APT=(make cmake gcc)

SW_LLVM_CLANG_APT=(make cmake gcc g++ clang clang-format clang-tools)

SW_NS_NPM=(n nativescript)

SW_MEDIA_APT=(ffmpeg sox)
SW_MEDIA_PIP=(yt-dlp pipx)

SW_QUAKE_APT=(clang clang-format clang-tools make cmake gcc g++ libc6-dev libsdl2-dev)

# ── Helpers ─────────────────────────────────────────────────────────
_apt_install() {
    [ $# -eq 0 ] && return 0
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}
_npm_install() {
    [ $# -eq 0 ] && return 0
    npm install -g --force "$@"
}
_pip_install() {
    [ $# -eq 0 ] && return 0
    pip3 install --break-system-packages "$@"
}
_gem_install() {
    [ $# -eq 0 ] && return 0
    gem install "$@" || true
}
_go_install() {
    [ $# -eq 0 ] && return 0
    local pkg
    for pkg in "$@"; do
        GOBIN=/usr/local/bin go install "$pkg" || true
    done
}

_is_true() {
    case "${1,,}" in
        true|yes|on|1) return 0 ;;
        *)             return 1 ;;
    esac
}

echo "[DEVPACK] refreshing apt cache..."
apt-get update

# ── SECURITY ────────────────────────────────────────────────────────
if _is_true "${INSTALL_SECURITY:-false}"; then
    echo "[DEVPACK] SECURITY group"
    _apt_install "${SW_SECURITY_APT[@]}"
    # Go toolchain: Debian bookworm's golang-go is 1.19 — too old for nuclei/v3,
    # httpx, subfinder/v2, and owasp-amass/v4. Install upstream Go directly.
    GO_VER="1.22.12"
    case "$(uname -m)" in
        x86_64|amd64) GO_ARCH=amd64 ;;
        aarch64|arm64) GO_ARCH=arm64 ;;
        *) GO_ARCH=amd64 ;;
    esac
    echo "[DEVPACK] SECURITY → installing Go ${GO_VER} (${GO_ARCH}) — apt golang-go is too old for projectdiscovery tools"
    if curl -sL "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz \
        && rm -rf /usr/local/go \
        && tar -C /usr/local -xzf /tmp/go.tgz \
        && ln -sf /usr/local/go/bin/go /usr/local/bin/go \
        && ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt \
        && rm -f /tmp/go.tgz; then
        _go_install "${SW_SECURITY_GO[@]}"
    else
        echo "[DEVPACK][WARNING] Go ${GO_VER} install failed — skipping Go-based security tools"
    fi
    # feroxbuster: prebuilt binary from GitHub releases.
    echo "[DEVPACK] SECURITY → feroxbuster (prebuilt)"
    curl -sL "$SW_SECURITY_FEROX_URL" -o /tmp/ferox.tgz \
        && tar -xzf /tmp/ferox.tgz -C /usr/local/bin feroxbuster \
        && chmod +x /usr/local/bin/feroxbuster \
        && rm -f /tmp/ferox.tgz \
        || echo "[DEVPACK][WARNING] feroxbuster install failed — skipping"
    # nikto: upstream git clone (not in Debian bookworm).
    echo "[DEVPACK] SECURITY → nikto (git)"
    git clone --depth 1 "$SW_SECURITY_NIKTO_REPO" /opt/nikto \
        && ln -sf /opt/nikto/program/nikto.pl /usr/local/bin/nikto \
        && chmod +x /opt/nikto/program/nikto.pl \
        || echo "[DEVPACK][WARNING] nikto install failed — skipping"
fi

# ── RUBY ────────────────────────────────────────────────────────────
if _is_true "${INSTALL_RUBY:-false}"; then
    echo "[DEVPACK] RUBY group"
    _apt_install "${SW_RUBY_APT[@]}"
    # cocoapods needs a working ruby — rbenv ships one, but the apt rbenv
    # package doesn't wire up an interactive shell. Try gem install against
    # the system ruby (if any) and let it fail loud rather than silently.
    _gem_install "${SW_RUBY_GEM[@]}"
fi

# ── CPP (minimal C/C++ chain) ───────────────────────────────────────
if _is_true "${INSTALL_CPP:-false}"; then
    echo "[DEVPACK] CPP group"
    _apt_install "${SW_CPP_APT[@]}"
fi

# ── LLVM / Clang (superset of CPP) ──────────────────────────────────
if _is_true "${INSTALL_LLVM_CLANG:-false}"; then
    echo "[DEVPACK] LLVM_CLANG group"
    _apt_install "${SW_LLVM_CLANG_APT[@]}"
fi

# ── NativeScript ────────────────────────────────────────────────────
if _is_true "${INSTALL_NS:-false}"; then
    echo "[DEVPACK] NS group"
    _npm_install "${SW_NS_NPM[@]}"
fi

# ── MEDIA ───────────────────────────────────────────────────────────
if _is_true "${INSTALL_MEDIA:-false}"; then
    echo "[DEVPACK] MEDIA group"
    _apt_install "${SW_MEDIA_APT[@]}"
    _pip_install "${SW_MEDIA_PIP[@]}"
fi

# ── QUAKE (full native build chain for the Quake port) ──────────────
if _is_true "${INSTALL_QUAKE:-false}"; then
    echo "[DEVPACK] QUAKE group"
    _apt_install "${SW_QUAKE_APT[@]}"
fi

# ── SSH (openssh-server only when user enabled SSH in llm-docker.conf) ────
if _is_true "${LLM_DOCKER_SSH_ENABLED:-false}"; then
    echo "[DEVPACK] SSH group"
    _apt_install openssh-server
fi

# ── TMUX HELPERS (opt-in — each gated by INSTALL_TMUX_*) ─────────────────
# vanilla      (just `tmux` apt pkg)     — wrap the tool in a tmux session              → INSTALL_TMUX_VANILLA
# team         (tmux + helper scripts)   — multi-pane team layout in one container      → INSTALL_TMUX_TEAM
# recon        (gavraz/recon)            — tmux-native Claude Code session dashboard    → INSTALL_TMUX_RECON
# codeman      (Ark0N/Codeman)           — web UI for Claude/OpenCode session mgmt      → INSTALL_TMUX_CODEMAN
# claude-tmux  (nielsgroen/claude-tmux)  — tmux popup for Claude Code session mgmt      → INSTALL_TMUX_CLAUDE
# apt tmux is installed if any of the five flags is true. Rustup only when a
# Rust-based helper is enabled (recon / claude-tmux).

_tmux_any=false
for _flag in INSTALL_TMUX_VANILLA INSTALL_TMUX_TEAM INSTALL_TMUX_RECON INSTALL_TMUX_CODEMAN INSTALL_TMUX_CLAUDE; do
    _is_true "${!_flag:-false}" && _tmux_any=true
done
unset _flag

if [ "$_tmux_any" = true ]; then
    echo "[DEVPACK] installing tmux (base package for all tmux modes)..."
    _apt_install tmux
fi

_tmux_need_rustup=false
_is_true "${INSTALL_TMUX_RECON:-false}"  && _tmux_need_rustup=true
_is_true "${INSTALL_TMUX_CLAUDE:-false}" && _tmux_need_rustup=true

if [ "$_tmux_need_rustup" = true ]; then
    echo "[DEVPACK] installing rustup (build dependency for recon / claude-tmux)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
    export PATH="/root/.cargo/bin:$PATH"
fi

if _is_true "${INSTALL_TMUX_RECON:-false}"; then
    echo "[DEVPACK] installing recon (gavraz/recon)..."
    cargo install -v --git https://github.com/gavraz/recon --locked || \
        echo "[DEVPACK][WARNING] recon build failed — skipping"
    if [ -x /root/.cargo/bin/recon ]; then
        mv /root/.cargo/bin/recon /usr/local/bin/recon
        chmod +x /usr/local/bin/recon
    fi
fi

if _is_true "${INSTALL_TMUX_CLAUDE:-false}"; then
    echo "[DEVPACK] installing claude-tmux (nielsgroen/claude-tmux)..."
    cargo install -v --git https://github.com/nielsgroen/claude-tmux --locked || \
        cargo install -v claude-tmux --locked || \
        echo "[DEVPACK][WARNING] claude-tmux build failed — skipping"
    if [ -x /root/.cargo/bin/claude-tmux ]; then
        mv /root/.cargo/bin/claude-tmux /usr/local/bin/claude-tmux
        chmod +x /usr/local/bin/claude-tmux
    fi
fi

if [ "$_tmux_need_rustup" = true ]; then
    echo "[DEVPACK] uninstalling rustup (keep image lean)..."
    /root/.cargo/bin/rustup self uninstall -y 2>/dev/null || true
    rm -rf /root/.cargo /root/.rustup
fi

if _is_true "${INSTALL_TMUX_CODEMAN:-false}"; then
    echo "[DEVPACK] installing codeman (Ark0N/Codeman)..."
    # Codeman pulls puppeteer + playwright as dev deps — both download Chromium
    # browser bundles (~150-300 MB each) on npm install. That's what makes
    # "==> Installing dependencies..." look frozen for 10+ minutes on arm64.
    # Codeman's server runtime doesn't need them, so we block the downloads.
    export PUPPETEER_SKIP_DOWNLOAD=true
    export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
    # Make npm chatty so the log shows progress instead of silent hangs.
    export NPM_CONFIG_LOGLEVEL=info
    export NPM_CONFIG_PROGRESS=true
    export NPM_CONFIG_FUND=false
    export NPM_CONFIG_AUDIT=false
    curl -fsSL https://raw.githubusercontent.com/Ark0N/Codeman/master/install.sh | bash \
        || echo "[DEVPACK][WARNING] codeman install failed — skipping"
    if [ ! -x /usr/local/bin/codeman ] && [ -x /root/.codeman/bin/codeman ]; then
        ln -sf /root/.codeman/bin/codeman /usr/local/bin/codeman
    fi
fi

# ── Cleanup ─────────────────────────────────────────────────────────
rm -rf /var/lib/apt/lists/*
echo "[DEVPACK] done"
