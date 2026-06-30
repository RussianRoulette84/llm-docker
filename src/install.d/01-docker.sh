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

# iTerm2 powers the live builder-api + cld-status side panels (`cld -a`) — split
# panes, positioning, the dashboard. Not required (Terminal.app falls back to a
# single window), but strongly recommended on macOS. The link is an OSC-8
# hyperlink with the raw URL as visible text, so it's clickable in iTerm and
# Cmd-clickable in Terminal.app either way.
if [[ "$OSTYPE" == "darwin"* ]] && [ ! -d "/Applications/iTerm.app" ]; then
    _itm_url="https://iterm2.com/downloads.html"
    warn "iTerm2 not found — recommended for the live builder-api + cld-status panels (cld -a)."
    printf '%b  %b[INFO]%b Get it free: \033]8;;%s\033\\%s\033]8;;\033\\\n' \
        "$(get_accent)" "$CYAN" "$RESET" "$_itm_url" "$_itm_url" >&2
    unset _itm_url
fi

