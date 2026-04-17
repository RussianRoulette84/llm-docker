#!/bin/bash
# llm-docker installer
#
# One-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/llm_docker/master/install.sh)
#
# Or from cloned repo:
#   ./install.sh

set -e

REPO_URL="https://github.com/RussianRoulette84/llm_docker.git"
INSTALL_DIR="$HOME/llm_docker"

# If run via curl/pipe (not from inside the repo), clone first
if [ ! -f "$(dirname "$0")/Dockerfile" ] 2>/dev/null; then
    echo "Cloning llm_docker..."
    if [ -d "$INSTALL_DIR" ]; then
        echo "  $INSTALL_DIR already exists, pulling latest..."
        git -C "$INSTALL_DIR" pull
    else
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    exec "$INSTALL_DIR/install.sh"
fi

SCRIPT_DIR="$( cd "$( dirname "$( realpath "${BASH_SOURCE[0]}" )" )" && pwd )"

C1='\033[38;5;209m'
C2='\033[38;5;214m'
DIM='\033[2m'
RST='\033[0m'
GRN='\033[38;5;82m'
STEP_COLOR='\033[38;5;81m'

_step() { printf "\n${STEP_COLOR}[%s]${RST} %s\n" "$1" "$2"; }
_ok()   { printf "  ${GRN}OK${RST}  %s\n" "$1"; }

printf "\n"
printf "  ${C1} ██╗     ██╗     ███╗   ███╗${RST}\n"
printf "  ${C2} ██║     ██║     ████╗ ████║${RST}\n"
printf "  ${C1} ██║     ██║     ██╔████╔██║${RST}\n"
printf "  ${C2} ██║     ██║     ██║╚██╔╝██║${RST}\n"
printf "  ${C1} ███████╗███████╗██║ ╚═╝ ██║${RST}\n"
printf "  ${C2} ╚══════╝╚══════╝╚═╝     ╚═╝${RST}\n"
printf "  ${DIM}docker installer${RST}\n"
printf "\n"

# ── 1. Docker ────────────────────────────────────────────────────────────────
_step "1/5" "Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
    echo "  Docker is not installed."
    echo "  Install it from https://www.docker.com/products/docker-desktop"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "  Docker is installed but not running."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Starting Docker Desktop..."
        open -a Docker
        echo "  Waiting for Docker to start..."
        until docker info >/dev/null 2>&1; do sleep 2; done
    else
        echo "  Please start Docker and re-run this script."
        exit 1
    fi
fi
_ok "Docker is ready"

# ── 2. Data directories ─────────────────────────────────────────────────────
_step "2/5" "Creating data directories..."
mkdir -p "$HOME/.llm_docker/claude"
mkdir -p "$HOME/.llm_docker/opencode"
_ok "~/.llm_docker/"

# ── 3. .env ──────────────────────────────────────────────────────────────────
_step "3/5" "Setting up .env..."
if [ -f "$SCRIPT_DIR/.env" ]; then
    _ok ".env already exists"
else
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    _ok "Created .env from template"
    printf "\n  ${C1}*** Don't forget to add your API keys to .env ***${RST}\n\n"
fi

# ── 4. Build image ──────────────────────────────────────────────────────────
_step "4/5" "Building Docker image..."
docker build --no-cache -t llm-docker:latest "$SCRIPT_DIR"
# Clear build logs and show clean status
printf "\033[2J\033[H"
_ok "Docker Build Done"

# ── 5. Link commands ────────────────────────────────────────────────────────
_step "5/5" "Linking cld and ocd to /usr/local/bin..."
NEED_SUDO=false
if [ ! -w /usr/local/bin ]; then
    NEED_SUDO=true
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
    _ok "$CMD -> $DST"
}

link_cmd cld
link_cmd ocd

printf "\n"
printf "  ${GRN}╔══════════════════════════════════╗${RST}\n"
printf "  ${GRN}║   (^_^)/  Installation complete! ║${RST}\n"
printf "  ${GRN}╚══════════════════════════════════╝${RST}\n"
printf "\n"
printf "  ${C2}Usage:${RST}\n"
printf "    ${C1}cld${RST}              Claude Code\n"
printf "    ${C1}cld -c${RST}           Continue last session\n"
printf "    ${C1}cld 4${RST}            4 terminals (macOS)\n"
printf "    ${C1}cld -c 4${RST}         4 terminals + session restore\n"
printf "    ${C1}ocd${RST}              OpenCode\n"
printf "\n"
if [ ! -f "$SCRIPT_DIR/.env" ] || ! grep -q "^ANTHROPIC_API_KEY=" "$SCRIPT_DIR/.env" 2>/dev/null; then
    printf "  ${C1}*** Don't forget to add your API keys to .env ***${RST}\n\n"
fi
