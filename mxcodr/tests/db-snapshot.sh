#!/usr/bin/env bash
# tests/db-snapshot.sh -- one database snapshot per agent session, rolled back after its first DONE.
#
#   bash tests/db-snapshot.sh take      # before the session's first test (gate.sh, orient.sh and
#                                       # film.sh call it); does nothing once taken
#   bash tests/db-snapshot.sh status    # what is pending, and when it was taken
#
# MDL_DB_RESET=session in tests/harness.env (the person's file) turns it on. Browser tests commit on
# every click -- Mendix has no transaction around a whole session the way UnitTesting rolls back one
# microflow -- so the data a session's tests create stayed, run after run: on InvoiceB2B the suite
# spent a seeded customer's credit until the approval tests were refused (2026-10-07). Instead:
#   take     pg_dump of the dev database while the app runs (0.5 s for 30 MB, measured)
#   restore  after the session's first full DONE (tests/gate.sh): pg_restore into a database beside
#            it while the app still runs, stop the app, swap the two by renaming, boot it again
#            (about 30 s); a failure at any step leaves the database as it was and boots the app.
# The session is the id the hooks write to .mxcli/session.id at its start; without one, a snapshot
# is taken at the first gate after a restore, so it is once per DONE instead.
# Local PostgreSQL only (MDL_DB_HOST on this machine), not in Docker mode. What the session wrote
# on purpose goes too -- data the app needs belongs in its after-startup seed, not in an exec.
# Exit 0 always for take and status: a snapshot that cannot be taken is said, never fatal.
# Sourced by tests/gate.sh for dbsnap_take and dbsnap_restore; not when run on its own.

DBSNAP_DIR=".mxcli/db-snapshot"

# True when MDL_DB_RESET=session applies here; sets the connection the other functions use.
dbsnap_enabled() {
  [ "${MDL_DB_RESET:-}" = "session" ] || return 1
  [ "${MDL_RUN_MODE:-}" = "docker" ] && return 1
  case "${MDL_DB_NAME:-}" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  DBSNAP_HOST="${MDL_DB_HOST:-127.0.0.1:5432}"
  DBSNAP_PORT="${DBSNAP_HOST##*:}"; DBSNAP_HOST="${DBSNAP_HOST%%:*}"
  case "$DBSNAP_PORT" in ''|*[!0-9]*) DBSNAP_PORT=5432 ;; esac
  case "$DBSNAP_HOST" in 127.0.0.1|localhost|::1) ;; *) return 1 ;; esac
  DBSNAP_USER="${MDL_DB_USER:-mendix}"
  DBSNAP_DB="$MDL_DB_NAME"
  # pg_dump and pg_restore sit beside psql (MDL_PSQL), else on PATH.
  DBSNAP_BIN=""
  if [ -n "${MDL_PSQL:-}" ] && [ -x "$MDL_PSQL" ]; then DBSNAP_BIN="$(dirname "$MDL_PSQL")/"; fi
  return 0
}

# dbsnap_pg <tool> <args...> -- a PostgreSQL client against this machine's server. The password is
# given per call, never exported to the tests.
dbsnap_pg() {
  local tool="$1"; shift
  local bin="${DBSNAP_BIN}${tool}"
  [ -x "$bin" ] || [ -x "$bin.exe" ] || bin="$tool"
  PGPASSWORD="${MDL_DB_PASSWORD:-mendix}" "$bin" -w -h "$DBSNAP_HOST" -p "$DBSNAP_PORT" -U "$DBSNAP_USER" "$@"
}

dbsnap_sql() { dbsnap_pg psql -d postgres -tAc "$1" 2>/dev/null; }

dbsnap_session() {
  local id
  id="$(cat .mxcli/session.id 2>/dev/null)"
  case "$id" in *[!A-Za-z0-9._-]*) id="" ;; esac
  printf '%s' "$id"
}

dbsnap_take() {
  dbsnap_enabled || return 0
  [ -f "$DBSNAP_DIR/pending.dump" ] && return 0
  local session
  session="$(dbsnap_session)"
  # This session already had its rollback: later runs leave the data alone.
  if [ -n "$session" ] && [ "$(cat "$DBSNAP_DIR/restored.session" 2>/dev/null)" = "$session" ]; then
    return 0
  fi
  # A new app's database appears with its first boot: nothing to keep yet, the next run takes it.
  [ "$(dbsnap_sql "SELECT 1 FROM pg_database WHERE datname='$DBSNAP_DB'")" = "1" ] || return 0
  mkdir -p "$DBSNAP_DIR" || return 0
  if dbsnap_pg pg_dump -Fc -f "$DBSNAP_DIR/pending.dump.tmp" "$DBSNAP_DB" 2>"$DBSNAP_DIR/take.err"; then
    mv "$DBSNAP_DIR/pending.dump.tmp" "$DBSNAP_DIR/pending.dump"
    printf 'session=%s\ntaken=%s\n' "$session" "$(date '+%Y-%m-%d %H:%M:%S')" > "$DBSNAP_DIR/pending.info"
    echo "   database snapshot taken (MDL_DB_RESET=session): the data goes back to it after this session's first DONE"
  else
    rm -f "$DBSNAP_DIR/pending.dump.tmp"
    echo "   !! MDL_DB_RESET=session: no database snapshot -- pg_dump failed: $(tail -1 "$DBSNAP_DIR/take.err" 2>/dev/null)"
  fi
  return 0
}

# dbsnap_restore -- after the session's first full DONE. Needs the gate's stop_project_app and
# ensure_app. Prints what happened; never leaves the app down when it can be booted.
dbsnap_restore() {
  dbsnap_enabled || return 0
  [ -f "$DBSNAP_DIR/pending.dump" ] || return 0
  local side="${DBSNAP_DB}_restored" old="${DBSNAP_DB}_before_restore" taken
  taken="$(sed -n 's/^taken=//p' "$DBSNAP_DIR/pending.info" 2>/dev/null)"
  echo "== rolling the database back to the start of this session (MDL_DB_RESET=session, snapshot ${taken:-?})"
  # 1. The snapshot into a database beside the live one, while the app still runs.
  dbsnap_sql "DROP DATABASE IF EXISTS \"$side\"" >/dev/null
  if ! dbsnap_sql "CREATE DATABASE \"$side\"" >/dev/null \
     || ! dbsnap_pg pg_restore --no-owner -d "$side" "$DBSNAP_DIR/pending.dump" 2>"$DBSNAP_DIR/restore.err"; then
    dbsnap_sql "DROP DATABASE IF EXISTS \"$side\"" >/dev/null
    echo "   !! the snapshot could not be restored ($(tail -1 "$DBSNAP_DIR/restore.err" 2>/dev/null)); the data stays as the tests left it"
    return 0
  fi
  # 2. Swap: the app holds connections, so it stops first; the rename itself is instant.
  stop_project_app >/dev/null 2>&1
  sleep 1
  dbsnap_sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DBSNAP_DB' AND pid <> pg_backend_pid()" >/dev/null
  dbsnap_sql "DROP DATABASE IF EXISTS \"$old\"" >/dev/null
  if ! dbsnap_sql "ALTER DATABASE \"$DBSNAP_DB\" RENAME TO \"$old\"" >/dev/null; then
    echo "   !! the database could not be renamed; the data stays as the tests left it"
    dbsnap_sql "DROP DATABASE IF EXISTS \"$side\"" >/dev/null
    dbsnap_boot
    return 0
  fi
  if ! dbsnap_sql "ALTER DATABASE \"$side\" RENAME TO \"$DBSNAP_DB\"" >/dev/null; then
    dbsnap_sql "ALTER DATABASE \"$old\" RENAME TO \"$DBSNAP_DB\"" >/dev/null
    echo "   !! the restored database could not take the name; the data stays as the tests left it"
    dbsnap_boot
    return 0
  fi
  # 3. Boot on it. If the app does not come up, the swap is undone and it boots on the old data.
  if ! dbsnap_boot; then
    echo "   !! the app did not start on the restored data; putting the previous database back"
    stop_project_app >/dev/null 2>&1
    sleep 1
    dbsnap_sql "ALTER DATABASE \"$DBSNAP_DB\" RENAME TO \"$side\"" >/dev/null
    dbsnap_sql "ALTER DATABASE \"$old\" RENAME TO \"$DBSNAP_DB\"" >/dev/null
    dbsnap_boot
    return 0
  fi
  # 4. Done: the previous database stays as <name>_before_restore until the next rollback, and the
  # last three snapshots stay in .mxcli/db-snapshot/ for a rollback by hand.
  mv "$DBSNAP_DIR/pending.dump" "$DBSNAP_DIR/restored-$(date '+%Y%m%d-%H%M%S').dump"
  ls -1t "$DBSNAP_DIR"/restored-*.dump 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done
  # The session that just had its rollback: the one running now. A snapshot left pending by an earlier
  # session that never reached DONE is still the one restored, but the session it was taken in is
  # not this one -- recording that one made the next gate here take a second snapshot (B2B, 2026-10-07).
  dbsnap_session > "$DBSNAP_DIR/restored.session" 2>/dev/null
  rm -f "$DBSNAP_DIR/pending.info"
  echo "   the data is back to ${taken:-the snapshot}, and the app runs on it; what the tests created is gone"
  echo "   (the previous data is kept as the database ${old})"
  return 0
}

# Boots the app in a subshell: ensure_app exits the gate when a boot fails.
dbsnap_boot() {
  ( BOOT=1; BASE_URL=""; ensure_app ) >/dev/null 2>&1
  answers "http://localhost:${APP_PORT:-8081}"
}

dbsnap_status() {
  if ! dbsnap_enabled; then
    echo "MDL_DB_RESET=session is off here (or the database is not a local PostgreSQL): no snapshot is taken"
    return 0
  fi
  if [ -f "$DBSNAP_DIR/pending.dump" ]; then
    echo "pending snapshot of $DBSNAP_DB, taken $(sed -n 's/^taken=//p' "$DBSNAP_DIR/pending.info" 2>/dev/null); restored after the first full DONE"
  elif [ -n "$(dbsnap_session)" ] && [ "$(cat "$DBSNAP_DIR/restored.session" 2>/dev/null)" = "$(dbsnap_session)" ]; then
    echo "this session's rollback is done; the next session takes a new snapshot"
  else
    echo "no pending snapshot; the next gate, orient or film run takes one"
  fi
  ls -1t "$DBSNAP_DIR"/restored-*.dump 2>/dev/null | head -3 | sed 's/^/kept: /'
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0
  . tests/portable.sh
  case "${1:-}" in
    take) dbsnap_take ;;
    status) dbsnap_status ;;
    *) echo "usage: bash tests/db-snapshot.sh take|status" >&2; exit 2 ;;
  esac
  exit 0
fi
