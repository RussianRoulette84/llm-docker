#!/usr/bin/env bash
# opencode-db.sh — SQLite safety for OpenCode inside llm-docker.
#
# WHY: opencode's WAL-mode database corrupted repeatedly (GitHub
# anomalyco/opencode#14970) while its data dir sat on the macOS bind mount
# (virtiofs). WAL needs shared-memory + locking guarantees virtiofs (like
# NFS) does not provide when several opencode processes write at once.
#
# WHAT: the live data dir lives on a Docker named volume (real ext4 —
# WAL-safe, persists across container rebuilds). This script keeps the
# macOS side (the mirror mount) in sync as a disaster-recovery copy:
#
#   DB transport (litestream, preferred):
#     bootstrap: empty volume + existing replica -> `litestream restore`
#     live:      one `litestream replicate` process streams WAL frames to
#                the mirror continuously (KBs per write burst — the
#                sqlite3 .backup path rewrites the whole 1GB file every
#                pass, ~2.5min; litestream is sub-second).
#                Guarded by a lock: ONE replicator serves the shared
#                volume no matter how many ocd containers run.
#   DB transport (fallback, LOUD):
#     no litestream binary -> WARNING + the old .backup watcher. Works,
#     slow. There is no silent fallback: the mode is logged at every boot.
#   Small files (always): auth.json + slot_N.id mirrored by a poll loop
#     after each change, plus one final sync at container exit.
#
# Every step logs event=... lines to the console AND the host-visible
# mirror dir (db-mirror.log) with durations, sizes and errors.

OC_DB_DATA_DIR="${OC_DB_DATA_DIR:-/root/.local/share/opencode}"
OC_DB_MIRROR_DIR="${OC_DB_MIRROR_DIR:-/mnt/opencode-mirror}"
OC_DB="$OC_DB_DATA_DIR/opencode.db"
OC_DB_MIRROR="$OC_DB_MIRROR_DIR/opencode.db"
OC_DB_REPLICA="$OC_DB_MIRROR_DIR/litestream-replica"
OC_DB_LOG="$OC_DB_MIRROR_DIR/db-mirror.log"
OC_DB_POLL_S="${OC_DB_POLL_S:-2}"      # how often the file watcher checks
OC_DB_QUIET_S="${OC_DB_QUIET_S:-2}"    # writes must pause this long before syncing
OC_DB_MAX_WAIT_S="${OC_DB_MAX_WAIT_S:-10}"  # cap: sync anyway after this, busy or not
OC_DB_WATCH_PID=""
OC_DB_LS_PID=""
OC_DB_LITESTREAM=0

_db_now_ms() { date +%s%3N; }

_dblog() {
    # _dblog LEVEL event=key value pairs...  -> console + mirror logfile
    local _lvl="$1"; shift
    local _line="[$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)] level=$_lvl $*"
    echo "[opencode-db] $_line"
    if [ -d "$OC_DB_MIRROR_DIR" ]; then
        # keep the log bounded: chop the head when it grows past 256 KB
        if [ -f "$OC_DB_LOG" ] && [ "$(stat -c %s "$OC_DB_LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
            tail -c 131072 "$OC_DB_LOG" > "$OC_DB_LOG.tmp" 2>/dev/null && mv "$OC_DB_LOG.tmp" "$OC_DB_LOG"
        fi
        echo "$_line" >> "$OC_DB_LOG" 2>/dev/null || true
    fi
}

_db_size() { stat -c %s "$1" 2>/dev/null || echo 0; }

# Fingerprint of everything this side mirrors. In litestream mode the DB
# itself is litestream's job — the watcher only carries the small files.
# sessions-index.tsv is regenerated on every sync, so it also acts as the
# "sessions changed" trigger.
_db_fingerprint() {
    local _files="$OC_DB_DATA_DIR/auth.json $OC_DB_DATA_DIR/sessions-index.tsv $OC_DB_DATA_DIR"/slot_*.id
    [ "$OC_DB_LITESTREAM" = 0 ] && _files="$OC_DB $OC_DB"-wal $_files
    stat -c '%n %s %Y' $_files 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

# Export the session table to a tiny TSV (id, directory, time_created,
# time_updated). The HOST launcher reads this instead of the DB itself —
# with litestream the plain mirror db is never refreshed, but the index is
# regenerated on every sync so host-side session lookups stay current.
_oc_db_export_index() {
    [ -f "$OC_DB" ] || return 0
    sqlite3 -separator '	' "$OC_DB" \
        "SELECT id, directory, time_created, time_updated FROM session ORDER BY time_created" \
        > "$OC_DB_DATA_DIR/sessions-index.tsv" 2>/dev/null || true
}

_oc_db_files_sync() {
    _oc_db_export_index
    local _f _list="auth.json sessions-index.tsv"
    for _f in "$OC_DB_DATA_DIR"/slot_*.id; do
        [ -f "$_f" ] && _list="$_list $(basename "$_f")"
    done
    for _f in $_list; do
        [ -f "$OC_DB_DATA_DIR/$_f" ] || continue
        if ! cmp -s "$OC_DB_DATA_DIR/$_f" "$OC_DB_MIRROR_DIR/$_f"; then
            cp -p "$OC_DB_DATA_DIR/$_f" "$OC_DB_MIRROR_DIR/$_f" \
                && _dblog INFO event=file_mirrored "file=$_f" "bytes=$(_db_size "$OC_DB_DATA_DIR/$_f")" \
                || _dblog ERROR event=file_mirror_failed "file=$_f"
        fi
    done
}

# Fallback DB transport only (litestream absent): full online-backup pass.
# Safe while opencode writes, but rewrites the whole file every time.
_oc_db_backup_once() {
    local _wait=""
    [ "${1:-}" = "--wait" ] && _wait=1
    local _t0=$(_db_now_ms)
    if [ ! -f "$OC_DB" ]; then
        _dblog ERROR event=mirror_skipped reason="no db on volume path=$OC_DB"
        return 1
    fi
    if [ -n "$_wait" ]; then
        flock -w 30 7 || _dblog ERROR event=mirror_lock_timeout "waited 30s for mirror lock"
    elif ! flock -n 7; then
        _dblog INFO event=mirror_skipped reason="another instance is mirroring"
        return 0
    fi
    _dblog INFO event=mirror_start "pid=$$"
    local _rc=0 _errf _bp _es
    _errf="$(mktemp)"
    # Full-file backup can take minutes — heartbeat to the console so an
    # exit never looks frozen while DB I/O is still running.
    sqlite3 "$OC_DB" ".backup '$OC_DB_MIRROR'" 2>"$_errf" &
    _bp=$!
    while kill -0 "$_bp" 2>/dev/null; do
        sleep 5
        if kill -0 "$_bp" 2>/dev/null; then
            _es=$(( $(_db_now_ms) / 1000 - _t0 / 1000 ))
            _dblog INFO event=mirror_heartbeat "elapsed_s=${_es}"
        fi
    done
    if wait "$_bp"; then
        [ -s "$_errf" ] && _dblog WARN event=backup_stderr "msg=$(head -c 300 "$_errf" | tr '\n' ' ')"
    else
        _dblog ERROR event=mirror_backup_failed "err=$(head -c 300 "$_errf" | tr '\n' ' ')"
        _rc=1
    fi
    /bin/rm -f "$_errf"
    _dblog INFO event=mirror_done "dur_ms=$(( $(_db_now_ms) - _t0 ))" "db_bytes=$(_db_size "$OC_DB")" "mirror_bytes=$(_db_size "$OC_DB_MIRROR")" "rc=$_rc"
    return $_rc
} 7>"$OC_DB_MIRROR_DIR/.mirror.lock"

# One sync pass for whichever transports are active.
_oc_db_sync_once() {
    _oc_db_files_sync
    [ "$OC_DB_LITESTREAM" = 0 ] && _oc_db_backup_once "${1:-}"
    return 0
}

# Boot-time: seed an empty volume. Priority: litestream replica (fast,
# point-in-time), then the plain mirror db (compacted copy — the
# historical VACUUM INTO path), else a fresh history.
_oc_db_seed() {
    local _t0=$(_db_now_ms)
    if [ -f "$OC_DB" ]; then
        _dblog INFO event=seed_skipped reason="volume db already present bytes=$(_db_size "$OC_DB")"
        return 0
    fi
    mkdir -p "$OC_DB_DATA_DIR"
    if command -v litestream >/dev/null 2>&1 && [ -d "$OC_DB_REPLICA" ]; then
        _dblog INFO event=seed_start source=litestream "replica=$OC_DB_REPLICA"
        if litestream restore -o "$OC_DB" "file://$OC_DB_REPLICA" >>"$OC_DB_LOG" 2>&1; then
            _dblog INFO event=seed_done source=litestream "dur_ms=$(( $(_db_now_ms) - _t0 ))" "bytes=$(_db_size "$OC_DB")"
        else
            _dblog ERROR event=seed_failed source=litestream "falling back to mirror db copy"
        fi
    fi
    if [ ! -f "$OC_DB" ] && [ -f "$OC_DB_MIRROR" ]; then
        _t0=$(_db_now_ms)
        _dblog INFO event=seed_start source=mirror_db "bytes=$(_db_size "$OC_DB_MIRROR")"
        if sqlite3 "$OC_DB_MIRROR" "VACUUM INTO '$OC_DB'" >>"$OC_DB_LOG" 2>&1; then
            local _chk
            _chk="$(sqlite3 "file:$OC_DB?mode=ro" 'PRAGMA quick_check;' 2>/dev/null | head -1)"
            _dblog INFO event=seed_done source=mirror_db "dur_ms=$(( $(_db_now_ms) - _t0 ))" "bytes=$(_db_size "$OC_DB")" "quick_check=${_chk:-unknown}"
            [ "$_chk" = "ok" ] || _dblog ERROR event=seed_integrity "quick_check=${_chk:-unknown}"
        else
            _dblog ERROR event=seed_failed source=mirror_db
            return 1
        fi
    fi
    [ -f "$OC_DB" ] || _dblog INFO event=seed_skipped reason="no replica, no mirror — starting with a fresh history"
    # auth must never be lost to a wiped volume — pull it from the mirror
    if [ ! -f "$OC_DB_DATA_DIR/auth.json" ] && [ -f "$OC_DB_MIRROR_DIR/auth.json" ]; then
        cp -p "$OC_DB_MIRROR_DIR/auth.json" "$OC_DB_DATA_DIR/auth.json" \
            && _dblog INFO event=auth_seeded \
            || _dblog ERROR event=auth_seed_failed
    fi
    return 0
}

# Background watcher: poll the fingerprint; when writes pause for
# OC_DB_QUIET_S seconds run one sync pass. Bounded total wait — a session
# that streams continuously (a DB write every second) would trap a
# quiet-only counter forever, and syncing while busy is safe anyway.
_oc_db_watch() {
    _dblog INFO event=watch_start "poll_s=$OC_DB_POLL_S quiet_s=$OC_DB_QUIET_S max_wait_s=$OC_DB_MAX_WAIT_S" "litestream=$OC_DB_LITESTREAM"
    local _last _fp _stable _waited
    _last="$(_db_fingerprint)"
    while true; do
        sleep "$OC_DB_POLL_S"
        _fp="$(_db_fingerprint)"
        if [ "$_fp" != "$_last" ]; then
            _stable=0; _waited=0
            while [ "$_stable" -lt "$OC_DB_QUIET_S" ] && [ "$_waited" -lt "$OC_DB_MAX_WAIT_S" ]; do
                sleep 1
                _waited=$((_waited + 1))
                if [ "$(_db_fingerprint)" = "$_fp" ]; then
                    _stable=$((_stable + 1))
                else
                    _fp="$(_db_fingerprint)"
                    _stable=0
                fi
            done
            [ "$_stable" -lt "$OC_DB_QUIET_S" ] \
                && _dblog INFO event=sync_busy_timeout "waited_s=$_waited (writes never paused — syncing anyway)"
            _oc_db_sync_once || true
            _last="$(_db_fingerprint)"
        fi
    done
}

# One litestream replicator per VOLUME (not per container): the lock in
# the replica dir decides who runs it. Losers log and rely on the winner.
_oc_db_start_litestream() {
    command -v litestream >/dev/null 2>&1 || return 1
    OC_DB_LITESTREAM=1
    mkdir -p "$OC_DB_REPLICA"
    (
        flock -n 8 || { echo "[opencode-db] $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) level=INFO event=litestream_skip reason=replicator-already-running"; exit 0; }
        exec litestream replicate "$OC_DB" "file://$OC_DB_REPLICA"
    ) >>"$OC_DB_LOG" 2>&1 8>"$OC_DB_REPLICA/.replicator.lock" &
    OC_DB_LS_PID=$!
    # Detach from the shell's job table: the exit path SIGKILLs this worker
    # when it ignores SIGTERM (observed) — bash must not print the
    # `NNN Killed ( ... )` job notification into the user's terminal.
    disown "$OC_DB_LS_PID" 2>/dev/null || true
    _dblog INFO event=litestream_start "pid=$OC_DB_LS_PID" "replica=$OC_DB_REPLICA"
    return 0
}

# Called from docker-entrypoint.sh (TOOL=opencode branch) before opencode
# starts: seed if needed, start DB transport + file watcher.
_oc_db_bootstrap() {
    if [ ! -d "$OC_DB_MIRROR_DIR" ]; then
        _dblog ERROR event=bootstrap_missing_mirror "path=$OC_DB_MIRROR_DIR (host mount absent — mirror disabled, volume still safe)"
        return 0
    fi
    _oc_db_seed || true
    if ! _oc_db_start_litestream; then
        _dblog WARN event=litestream_missing "litestream not installed — falling back to SLOW full-file .backup mirroring (ocd --build reinstalls it)"
    fi
    _oc_db_watch &
    OC_DB_WATCH_PID=$!
    # Same as the litestream worker: no job-control kill notifications on exit.
    disown "$OC_DB_WATCH_PID" 2>/dev/null || true
    _dblog INFO event=watch_pid "pid=$OC_DB_WATCH_PID"
}

# Bounded stop: TERM, SHORT grace (default 0.5s, arg2 = grace in 0.1s
# steps), then KILL. Workers only ever READ the live DB (litestream
# replicator) or rewrite mirror files (watcher) — killing them mid-flight
# is safe; the final sync that runs right after is the authoritative copy.
# Keep the grace SHORT: litestream has been observed to sit through SIGTERM
# for the full window, and this runs on the Ctrl+C exit path where every
# 100ms is felt. Workers are disowned at launch (no `wait` here — any
# lingering zombie dies with the container a moment later).
_oc_db_stop_pid() {
    [ -n "${1:-}" ] || return 0
    kill "$1" 2>/dev/null
    local _i=0
    while kill -0 "$1" 2>/dev/null && [ "$_i" -lt "${2:-5}" ]; do
        sleep 0.1
        _i=$((_i + 1))
    done
    kill -9 "$1" 2>/dev/null
}

# Called from docker-entrypoint.sh after opencode exits (and from the
# signal cleanup path — guarded, runs once). Bounded: worst case ~1s —
# it sits on the Ctrl+C exit path.
_oc_db_finish() {
    [ "${OC_DB_FINISHED:-0}" = "1" ] && return 0
    OC_DB_FINISHED=1
    local _t0=$(_db_now_ms) _f0
    echo "[opencode-db] exit: stopping workers..."
    # litestream: 0.2s grace — it ignores TERM anyway; KILL is safe (it
    # only reads the live db, the replica is crash-safe). The watcher is a
    # bash loop and dies on TERM instantly.
    _oc_db_stop_pid "$OC_DB_LS_PID" 2
    _oc_db_stop_pid "$OC_DB_WATCH_PID"
    if [ "$OC_DB_LITESTREAM" = 0 ]; then
        # Fallback mode only: reap a possibly in-flight .backup so the
        # final copy below can take the mirror lock immediately. In
        # litestream mode nothing of ours runs the sqlite3 CLI.
        local _p
        for _p in $(pgrep -x sqlite3 2>/dev/null); do kill "$_p" 2>/dev/null; done
    fi
    echo "[opencode-db] exit: workers stopped ($(( $(_db_now_ms) - _t0 ))ms)"
    _f0=$(_db_now_ms)
    echo "[opencode-db] exit: final copy running..."
    _oc_db_sync_once --wait || true
    echo "[opencode-db] exit: DONE (copy $(( $(_db_now_ms) - _f0 ))ms, total $(( $(_db_now_ms) - _t0 ))ms)"
    _dblog INFO event=finish "dur_ms=$(( $(_db_now_ms) - _t0 ))"
}
