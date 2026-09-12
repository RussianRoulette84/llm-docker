#!/usr/bin/env bash
# ocd_db_restore.sh — OpenCode SQLite repair/restore. Run it, follow the menu. Never deletes.
#   --backup    backup current db to backups/ and exit (refuses corrupt db)
# Works standalone (macOS bash 3.2 or Linux) against $HOME/.local/share/opencode,
# and inside the llm-docker container via `ocd --dbrestore` (volume + replica visible).

DATA_DIR="$HOME/.local/share/opencode"
DB="$DATA_DIR/opencode.db"
BACKUPS="$DATA_DIR/backups"
TS="$(date +%Y%m%d_%H%M%S)"

# Litestream replica = freshest disaster-recovery copy. Container: mirror
# mount. Standalone on the Mac: the mirror dir IS ~/.local/share/opencode.
REPLICA=""
for _r in /mnt/opencode-mirror/litestream-replica "$DATA_DIR/litestream-replica"; do
    [ -d "$_r" ] && { REPLICA="$_r"; break; }
done
unset _r

c_ok()   { printf '\033[32m[ok]\033[0m  %s\n' "$*"; }
c_info() { printf '\033[36m[->]\033[0m  %s\n' "$*"; }
c_warn() { printf '\033[33m[!!]\033[0m  %s\n' "$*"; }
die()    { printf '\033[31m[x]\033[0m  %s\n' "$*"; exit 1; }

command -v sqlite3 >/dev/null || die "sqlite3 missing: apt-get install -y sqlite3"
mkdir -p "$BACKUPS"

# portable mtime (BSD date -r FILE vs GNU date -d @EPOCH)
mt() {
    if [ "$(uname)" = "Darwin" ]; then
        date -r "$1" +%m%d_%H%M 2>/dev/null
    else
        date -d "@$(stat -c %Y "$1" 2>/dev/null)" +%m%d_%H%M 2>/dev/null
    fi
}

# probe <dbfile> -> "state msgs"
probe() {
  local f="$1" chk msgs
  [ -f "$f" ] || { echo "missing -"; return; }
  [ -s "$f" ] || { echo "empty -"; return; }
  chk="$(sqlite3 "file:$f?mode=ro" 'PRAGMA integrity_check;' 2>/dev/null | head -n1)"
  [ "$chk" = "ok" ] || { echo "corrupt -"; return; }
  sqlite3 "file:$f?mode=ro" '.tables' 2>/dev/null | grep -qw message || { echo "ok 0"; return; }
  msgs="$(sqlite3 "file:$f?mode=ro" 'SELECT count(*) FROM message;' 2>/dev/null)"
  echo "ok ${msgs:-0}"
}

# rebuild <dump.sql> <out.db> -> echoes msg count, or fails
rebuild() {
  sed 's/^ROLLBACK; -- due to errors$/COMMIT;/' "$1" | sqlite3 "$2" 2>/dev/null
  tail -c 200 "$1" | grep -q COMMIT || echo 'COMMIT;' | sqlite3 "$2" 2>/dev/null
  local st msgs; read -r st msgs <<< "$(probe "$2")"
  [ "$st" = "ok" ] && [ "$msgs" != "0" ] || return 1
  echo "$msgs"
}

# make_backup <dbfile> — safety copy after every successful restore/repair
make_backup() {
  local st msgs; read -r st msgs <<< "$(probe "$1")"
  [ "$st" = "ok" ] || return 0
  cp -a "$1" "$BACKUPS/opencode.bak_$TS.db"
  c_ok "backup made: $BACKUPS/opencode.bak_$TS.db ($msgs msgs)"
}

# swap <good-db> — archives current db, installs good one
do_swap() {
  mkdir -p "$DATA_DIR/db_restore_$TS"
  [ -f "$DB" ]     && mv "$DB"     "$DATA_DIR/db_restore_$TS/opencode_replaced.db"
  [ -f "$DB-wal" ] && mv "$DB-wal" "$DATA_DIR/db_restore_$TS/old.db-wal"
  [ -f "$DB-shm" ] && mv "$DB-shm" "$DATA_DIR/db_restore_$TS/old.db-shm"
  cp -a "$1" "$DB"
  c_ok "installed $1 -> $DB"
  make_backup "$DB"
  echo "restart opencode and send a test prompt."
}

# menu: candidates = litestream replica (if present) + .db files + dumps under DATA_DIR
pick_and_restore() {
  # shellcheck disable=SC2012
  c_info "scanning $DATA_DIR for candidates (.db files + .sql dumps)..."
  local FILES=()
  while IFS= read -r f; do
      FILES+=("$f")
  done < <(find "$DATA_DIR" -maxdepth 3 \( -name '*.db' ! -name '*-wal' ! -name '*-shm' -o -name 'dump.sql' -o -name 'recovered.sql' \) \
      ! -path "$DB" ! -path '*/.Trash/*' 2>/dev/null | sort)
  [ "${#FILES[@]}" -gt 0 ] || [ -n "$REPLICA" ] || die "no candidates found"

  printf '%-3s %-8s %-6s %-7s %-11s %s\n' "#" STATE MSGS SIZE MTIME PATH
  if [ -n "$REPLICA" ]; then
      printf '%-3s %-8s %-6s %-7s %-11s %s\n' "r" "replica" "live" \
        "$(du -sh "$REPLICA" 2>/dev/null | cut -f1)" "$(mt "$REPLICA")" "$REPLICA (litestream)"
  fi
  for i in "${!FILES[@]}"; do
    f="${FILES[$i]}"
    if [[ "$f" == *.sql ]]; then
      printf '%-3s %-8s %-6s %-7s %-11s %s\n' "$((i+1))" "dump" "?" \
        "$(du -h "$f" | cut -f1)" "$(mt "$f")" "$f"
    else
      read -r st msgs <<< "$(probe "$f")"
      printf '%-3s %-8s %-6s %-7s %-11s %s\n' "$((i+1))" "$st" "$msgs" \
        "$(du -h "$f" | cut -f1)" "$(mt "$f")" "$f"
    fi
  done
  read -r -p "number to restore ('r' = litestream replica, empty=abort): " n

  if [ "$n" = "r" ] || [ "$n" = "R" ]; then
    [ -n "$REPLICA" ] || die "no replica available"
    command -v litestream >/dev/null || die "litestream not installed"
    c_info "restoring from replica into a fresh db..."
    OUT="$BACKUPS/restored_$TS.db"
    litestream restore -o "$OUT" "file://$REPLICA" || die "litestream restore failed"
    read -r st msgs <<< "$(probe "$OUT")"
    [ "$st" = "ok" ] || die "restored db failed integrity check"
    c_ok "restored $OUT ($msgs messages)"
    do_swap "$OUT"
    exit 0
  fi

  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#FILES[@]}" ] || die "aborted"
  SEL="${FILES[$((n-1))]}"

  if [[ "$SEL" == *.sql ]]; then
    c_info "rebuilding db from dump $SEL ..."
    OUT="$BACKUPS/restored_$TS.db"
    MSGS="$(rebuild "$SEL" "$OUT")" || die "dump produced no usable db: $SEL"
    c_ok "rebuilt $OUT ($MSGS messages)"
    do_swap "$OUT"
  else
    read -r st msgs <<< "$(probe "$SEL")"
    [ "$st" = "ok" ]   || die "selected db is corrupt: $SEL"
    [ "$msgs" != "0" ] || die "selected db has 0 messages: $SEL"
    do_swap "$SEL"
  fi
  exit 0
}

# ================= main =================
if [ "$1" = "--backup" ]; then
  [ -f "$DB" ] || die "no db at $DB"
  read -r st msgs <<< "$(probe "$DB")"
  [ "$st" = "ok" ] || die "db is corrupt — refusing to backup a broken file ($DB)"
  cp -a "$DB" "$BACKUPS/opencode.bak_$TS.db"
  c_ok "backup made: $BACKUPS/opencode.bak_$TS.db ($msgs msgs)"
  exit 0
fi

[ -f "$DB" ] || { c_warn "no live db at $DB"; pick_and_restore; }

RESULT="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1)"
if [ "$RESULT" = "ok" ]; then
  read -r st msgs <<< "$(probe "$DB")"
  c_ok "database is healthy ($msgs messages) — nothing to do"
  exit 0
fi

c_warn "corruption detected ($(echo "$RESULT" | wc -l) issues)"
read -r -p "repair it? [y/N] (N = restore from backup/dump): " ans
case "$ans" in y|Y|yes|YES) ;; *) pick_and_restore ;; esac

pgrep -f opencode >/dev/null 2>&1 && die "stop opencode first"

WORK="$DATA_DIR/db_repair_$TS"
mkdir -p "$WORK"
c_info "backing up corrupt db to $WORK/"
cp -a "$DB" "$WORK/opencode_corrupt.db"
[ -f "$DB-wal" ] && cp -a "$DB-wal" "$WORK/opencode_corrupt.db-wal"
[ -f "$DB-shm" ] && cp -a "$DB-shm" "$WORK/opencode_corrupt.db-shm"

PRE="$(sqlite3 "$DB" 'SELECT count(*) FROM message;' 2>/dev/null)"
[ -n "$PRE" ] && c_info "pre-repair message count: $PRE"

c_info "extracting data..."
sqlite3 "$WORK/opencode_corrupt.db" '.recover' > "$WORK/recovered.sql" 2>/dev/null
SRC="$WORK/recovered.sql"
grep -q '^INSERT' "$SRC" || { c_warn ".recover empty — using .dump"; sqlite3 "$WORK/opencode_corrupt.db" '.dump' > "$WORK/dump.sql" 2>/dev/null; SRC="$WORK/dump.sql"; }

grep -qE 'INSERT INTO ["'"'"'`]?message' "$SRC" || { c_warn "dump has no message rows — dead end"; pick_and_restore; }

c_info "rebuilding from $SRC..."
MSGS="$(rebuild "$SRC" "$WORK/opencode_fixed.db")" || { c_warn "rebuild failed/empty"; pick_and_restore; }
c_ok "rebuilt db healthy, $MSGS messages"

if [ -n "$PRE" ] && [ "$MSGS" -lt $((PRE / 2)) ]; then
  c_warn "recovered $MSGS of ~$PRE messages (<50%)"
fi
read -r -p "swap repaired db into place? [y/N] " ans
case "$ans" in y|Y|yes|YES) ;; *) die "aborted — rebuilt db kept at $WORK/opencode_fixed.db" ;; esac

mv "$DB"     "$WORK/opencode_original.db"
[ -f "$DB-wal" ] && mv "$DB-wal" "$WORK/opencode_original.db-wal"
[ -f "$DB-shm" ] && mv "$DB-shm" "$WORK/opencode_original.db-shm"
cp -a "$WORK/opencode_fixed.db" "$DB"
c_ok "done — repaired db is now $DB ($MSGS messages)"
make_backup "$DB"
echo "restart opencode and send a test prompt."
