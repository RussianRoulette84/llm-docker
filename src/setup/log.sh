# setup/log.sh — module of the split setup.sh (sourced by the setup.sh loader).

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

