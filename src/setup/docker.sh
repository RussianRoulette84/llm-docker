# setup/docker.sh — Docker Desktop launch helpers (shared by cld + ocd).

# _ensure_docker_running TOOL — make sure Docker is up; start Docker Desktop on
# macOS if not. Serialized via a flock on /tmp/cld-docker-start.lock so parallel
# cld/ocd launches don't all fire `open -a Docker` into a mid-launch Docker
# Desktop (which crashes it with "Unrecognized event type 0" on macOS Sequoia).
# $1 is the log tag (CLD/OCD). Exits the launcher on a hard failure.
_ensure_docker_running() {
    local _tag="$1"
    docker info > /dev/null 2>&1 && return 0

    local _have_flock=true
    if ! command -v flock > /dev/null 2>&1; then
        _have_flock=false
        _log "$_tag" WARNING "flock not found — running without launch-race protection. Install with: brew install flock"
    fi
    if $_have_flock; then
        exec 9> "/tmp/cld-docker-start.lock"
        if ! flock -n 9; then
            _log "$_tag" "Another cld/ocd is starting Docker — waiting..."
            flock 9
        fi
    fi

    # Re-check inside the lock: an earlier holder may have already started Docker.
    if ! docker info > /dev/null 2>&1; then
        _log "$_tag" WARNING "Docker is not running — starting Docker Desktop..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # `open -a Docker` relies on LaunchServices. If Docker.app is in a
            # subfolder or LS's index is stale it silently fails — fall back to
            # an absolute-path launch so we don't wait 60s for nothing.
            if ! open -a Docker 2>/dev/null; then
                local _docker_app=""
                if command -v mdfind >/dev/null 2>&1; then
                    _docker_app="$(mdfind -name 'Docker.app' 2>/dev/null | grep -E '/Docker\.app$' | head -1)"
                fi
                if [ -z "$_docker_app" ]; then
                    _docker_app="$(find /Applications -maxdepth 4 -name 'Docker.app' -type d 2>/dev/null | head -1)"
                fi
                if [ -n "$_docker_app" ]; then
                    _log "$_tag" "Found Docker at $_docker_app — launching..."
                    open "$_docker_app"
                else
                    _log "$_tag" ERROR "Could not find Docker.app under /Applications. Install Docker Desktop or move it into /Applications."
                    exit 1
                fi
            fi
        else
            _log "$_tag" ERROR "Please start Docker manually on your system"
            exit 1
        fi

        _log "$_tag" "Waiting for Docker to start (this may take a minute)..."
        local max_wait=60 waited=0
        until docker info > /dev/null 2>&1; do
            if [ "$waited" -ge "$max_wait" ]; then
                _log "$_tag" ERROR "Docker did not start within $max_wait seconds"
                exit 1
            fi
            echo -n "."
            sleep 2
            waited=$((waited + 2))
        done
        _log "$_tag" "Docker is ready!"
    fi

    if $_have_flock; then exec 9>&-; fi
}
