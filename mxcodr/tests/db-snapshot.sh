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

# True when a reset applies here; sets the connection the other functions use. MDL_DB_RESET is
# `done` by default: every full DONE puts the data back to the snapshot (taken at the first gate after
# the previous reset), so what the tests created never stays in the app the person opens -- three
# InvoiceChase runs left 5-8 test customers and 6-11 test invoices on the owner's and the customer's
# pages (2026-10-12). `session`: only after a session's first DONE (the earlier behaviour). `off`: never.
dbsnap_enabled() {
  DBSNAP_MODE="${MDL_DB_RESET:-done}"
  case "$DBSNAP_MODE" in done|session) ;; *) return 1 ;; esac
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

# dbsnap_fingerprint -- one md5 over the content of every table the tests can change on purpose:
# all tables outside System.* and MendixSystem.* (own modules, Marketplace modules, Administration),
# plus the autonumber counters (mendixsystem$sequence), the users and their roles, uploaded files and
# images, and the workflow tables. Each row is its whole jsonb text (every column, so a status
# Unpaid->Paid with equal row counts changes it, and so does a new column after a model change),
# rows sorted, tables sorted by name. Left out as run-time churn: sessions, tokens, queued and
# processed tasks, scheduled-event bookkeeping, change hashes, offline sync state, time zones, the
# MendixSystem metadata -- and from System.User only lastlogin, failedlogins and changeddate, which a
# login rewrites. A user a test created, a role it granted, a password it changed all still count.
# Prints nothing (= unknown, so the caller swaps as before) when the query fails or the tables hold
# more than DBSNAP_FP_MAX_ROWS rows in all: hashing a big database costs more than it saves.
DBSNAP_FP_MAX_ROWS="${DBSNAP_FP_MAX_ROWS:-50000}"
dbsnap_fingerprint() {
  local sql out
  sql="$(cat <<'SQL'
WITH t AS (
  SELECT c.relname AS name
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname = 'public'
    AND ( (left(c.relname, 7) <> 'system$' AND left(c.relname, 13) <> 'mendixsystem$')
       OR c.relname IN ('mendixsystem$sequence', 'system$user', 'system$userroles', 'system$userrole',
                        'system$grantableroles', 'system$user_language', 'system$user_timezone',
                        'system$filedocument', 'system$privatefiledocument', 'system$image')
       OR left(c.relname, 15) = 'system$workflow')
), n AS (
  SELECT coalesce(sum(((xpath('/row/c/text()', query_to_xml(
           format('SELECT count(*) AS c FROM public.%I', name), false, true, '')))[1])::text::bigint), 0) AS rows
  FROM t
)
SELECT CASE WHEN n.rows > __MAX__ THEN '' ELSE (
  SELECT md5(string_agg(name || '=' || ((xpath('/row/h/text()', query_to_xml(
           format('SELECT coalesce(md5(string_agg(j::text, chr(10) ORDER BY j::text)), ''-'') AS h
                   FROM (SELECT to_jsonb(x) - %L::text[] AS j FROM public.%I x) s',
                  CASE WHEN name = 'system$user' THEN '{lastlogin,failedlogins,changeddate}' ELSE '{}' END, name),
           false, true, '')))[1])::text, ',' ORDER BY name)) FROM t) END
FROM n
SQL
)"
  sql="${sql//__MAX__/$DBSNAP_FP_MAX_ROWS}"
  out="$(dbsnap_pg psql -d "$DBSNAP_DB" -tAc "$sql" 2>/dev/null)" || return 0
  case "$out" in ''|*[!0-9a-f]*) return 0 ;; esac
  printf '%s' "$out"
}

dbsnap_session() {
  local id
  id="$(cat .mxcli/session.id 2>/dev/null)"
  case "$id" in *[!A-Za-z0-9._-]*) id="" ;; esac
  printf '%s' "$id"
}

# dbsnap_seed_hash -- the seed the database was filled by: one digest over the describe of the
# after-startup microflow and every microflow it calls, to 30 of them. `none` when the app has no
# after-startup microflow; nothing (unknown) without mxcli or the model. A snapshot taken before the
# seed was written, or before it changed, puts the old seed rows back: --reset-data then restores an
# empty or stale database, and an agent drops the schema by hand to get its seed back.
dbsnap_seed_hash() {
  local start flow text all="" todo seen=" " n=0 callee
  [ -n "${MXCLI:-}" ] && [ -n "${MPR:-}" ] && [ -f "$MPR" ] || return 0
  text="$("$MXCLI" -p "$MPR" -c "describe settings" 2>/dev/null)" || return 0
  [ -n "$text" ] || return 0
  start="$(printf '%s\n' "$text" | sed -n "s/.*AfterStartupMicroflow:[[:space:]]*'\([^']*\)'.*/\1/p" | head -1)"
  if [ -z "$start" ]; then printf 'none'; return 0; fi
  todo="$start"
  while [ -n "$todo" ] && [ "$n" -lt 30 ]; do
    flow="${todo%% *}"
    if [ "$flow" = "$todo" ]; then todo=""; else todo="${todo#* }"; fi
    case "$seen" in *" $flow "*) continue ;; esac
    seen="$seen$flow "; n=$((n + 1))
    text="$("$MXCLI" -p "$MPR" -c "describe microflow $flow" 2>/dev/null)"
    all="$all$text"
    for callee in $(printf '%s\n' "$text" | sed -n 's/.*call microflow[[:space:]]*\([A-Za-z0-9_.]*\).*/\1/p' | sort -u); do
      todo="${todo:+$todo }$callee"
    done
  done
  printf '%s' "$all" | cksum | cut -d' ' -f1
}

# dbsnap_seed_changed -- true when the pending snapshot was taken with another seed than the model's now.
dbsnap_seed_changed() {
  local was now
  was="$(sed -n 's/^seed=//p' "$DBSNAP_DIR/pending.info" 2>/dev/null)"
  [ -n "$was" ] || return 1
  now="$(dbsnap_seed_hash)"
  [ -n "$now" ] && [ "$now" != "$was" ]
}

# dbsnap_fresh -- an empty database the app boots on, so the current after-startup seed fills it; the
# old one stays as <name>_before_restore, and the pending snapshot goes (the gate takes a new one).
# The same stop and boot a restore costs. True when the app runs on it; otherwise the old data is back.
dbsnap_fresh() {
  local old="${DBSNAP_DB}_before_restore"
  stop_project_app >/dev/null 2>&1
  sleep 1
  dbsnap_sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DBSNAP_DB' AND pid <> pg_backend_pid()" >/dev/null
  dbsnap_sql "DROP DATABASE IF EXISTS \"$old\"" >/dev/null
  if ! dbsnap_sql "ALTER DATABASE \"$DBSNAP_DB\" RENAME TO \"$old\"" >/dev/null || ! dbsnap_sql "CREATE DATABASE \"$DBSNAP_DB\"" >/dev/null; then
    dbsnap_sql "ALTER DATABASE \"$old\" RENAME TO \"$DBSNAP_DB\"" >/dev/null
    echo "   !! no fresh database could be made; the data stays as it was"
    dbsnap_boot
    return 1
  fi
  if ! dbsnap_boot; then
    echo "   !! the app did not start on a fresh database; putting the previous one back"
    stop_project_app >/dev/null 2>&1
    sleep 1
    dbsnap_sql "DROP DATABASE IF EXISTS \"$DBSNAP_DB\"" >/dev/null
    dbsnap_sql "ALTER DATABASE \"$old\" RENAME TO \"$DBSNAP_DB\"" >/dev/null
    dbsnap_boot
    return 1
  fi
  mkdir -p "$DBSNAP_DIR"
  [ -f "$DBSNAP_DIR/pending.dump" ] && mv "$DBSNAP_DIR/pending.dump" "$DBSNAP_DIR/restored-$(date '+%Y%m%d-%H%M%S').dump"
  rm -f "$DBSNAP_DIR/pending.info" "$DBSNAP_DIR/pending.fp" "$DBSNAP_DIR/dirty"
  return 0
}

dbsnap_take() {
  dbsnap_enabled || return 0
  [ -f "$DBSNAP_DIR/pending.dump" ] && return 0
  local session
  session="$(dbsnap_session)"
  # session mode: this session already had its rollback, so later runs leave the data alone.
  if [ "$DBSNAP_MODE" = "session" ] && [ -n "$session" ] && [ "$(cat "$DBSNAP_DIR/restored.session" 2>/dev/null)" = "$session" ]; then
    return 0
  fi
  # A new app's database appears with its first boot: nothing to keep yet, the next run takes it.
  [ "$(dbsnap_sql "SELECT 1 FROM pg_database WHERE datname='$DBSNAP_DB'")" = "1" ] || return 0
  mkdir -p "$DBSNAP_DIR" || return 0
  local fp_before fp_after
  fp_before="$(dbsnap_fingerprint)"
  if dbsnap_pg pg_dump -Fc -f "$DBSNAP_DIR/pending.dump.tmp" "$DBSNAP_DB" 2>"$DBSNAP_DIR/take.err"; then
    # The fingerprint counts only when the content did not move while the dump ran.
    fp_after="$(dbsnap_fingerprint)"
    rm -f "$DBSNAP_DIR/pending.fp"
    [ -n "$fp_before" ] && [ "$fp_before" = "$fp_after" ] && printf '%s' "$fp_before" > "$DBSNAP_DIR/pending.fp"
    mv "$DBSNAP_DIR/pending.dump.tmp" "$DBSNAP_DIR/pending.dump"
    rm -f "$DBSNAP_DIR/unavailable"
    printf 'session=%s\ntaken=%s\nseed=%s\n' "$session" "$(date '+%Y-%m-%d %H:%M:%S')" "$(dbsnap_seed_hash)" > "$DBSNAP_DIR/pending.info"
    if [ "$DBSNAP_MODE" = "session" ]; then
      echo "   database snapshot taken (MDL_DB_RESET=session): the data goes back to it after this session's first DONE"
    else
      echo "   database snapshot taken: at DONE the data goes back to it, so test rows do not stay in the app (MDL_DB_RESET=off keeps them)"
    fi
  else
    rm -f "$DBSNAP_DIR/pending.dump.tmp"
    # Said once, not at every gate: without pg_dump there is nothing to do about it here.
    if [ ! -f "$DBSNAP_DIR/unavailable" ]; then
      echo "   !! no database snapshot, so test rows stay in the app -- pg_dump failed: $(tail -1 "$DBSNAP_DIR/take.err" 2>/dev/null)"
      : > "$DBSNAP_DIR/unavailable"
    fi
  fi
  return 0
}

# dbsnap_unchanged -- true when the live data has the fingerprint stored with the pending snapshot.
# Unknown (no stored fingerprint, a failed query, a database over the row limit) is false: swap.
dbsnap_unchanged() {
  local want have
  want="$(cat "$DBSNAP_DIR/pending.fp" 2>/dev/null)"
  [ -n "$want" ] || return 1
  have="$(dbsnap_fingerprint)"
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# dbsnap_swap -- the snapshot becomes the live database: restored beside it while the app still
# runs, the app stopped, the two swapped by renaming, the app booted on it. True when the app runs
# on the snapshot; otherwise says why and leaves the data (and the pending snapshot) as they were.
dbsnap_swap() {
  local side="${DBSNAP_DB}_restored" old="${DBSNAP_DB}_before_restore"
  # 1. The snapshot into a database beside the live one, while the app still runs.
  dbsnap_sql "DROP DATABASE IF EXISTS \"$side\"" >/dev/null
  if ! dbsnap_sql "CREATE DATABASE \"$side\"" >/dev/null \
     || ! dbsnap_pg pg_restore --no-owner -d "$side" "$DBSNAP_DIR/pending.dump" 2>"$DBSNAP_DIR/restore.err"; then
    dbsnap_sql "DROP DATABASE IF EXISTS \"$side\"" >/dev/null
    echo "   !! the snapshot could not be restored ($(tail -1 "$DBSNAP_DIR/restore.err" 2>/dev/null)); the data stays as the tests left it"
    return 1
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
    return 1
  fi
  if ! dbsnap_sql "ALTER DATABASE \"$side\" RENAME TO \"$DBSNAP_DB\"" >/dev/null; then
    dbsnap_sql "ALTER DATABASE \"$old\" RENAME TO \"$DBSNAP_DB\"" >/dev/null
    echo "   !! the restored database could not take the name; the data stays as the tests left it"
    dbsnap_boot
    return 1
  fi
  # 3. Boot on it. If the app does not come up, the swap is undone and it boots on the old data.
  if ! dbsnap_boot; then
    echo "   !! the app did not start on the restored data; putting the previous database back"
    stop_project_app >/dev/null 2>&1
    sleep 1
    dbsnap_sql "ALTER DATABASE \"$DBSNAP_DB\" RENAME TO \"$side\"" >/dev/null
    dbsnap_sql "ALTER DATABASE \"$old\" RENAME TO \"$DBSNAP_DB\"" >/dev/null
    dbsnap_boot
    return 1
  fi
  rm -f "$DBSNAP_DIR/dirty"
  return 0
}

# dbsnap_restore -- after the session's first full DONE. Needs the gate's stop_project_app and
# ensure_app. Prints what happened; never leaves the app down when it can be booted.
dbsnap_restore() {
  dbsnap_enabled || return 0
  [ -f "$DBSNAP_DIR/pending.dump" ] || return 0
  local old="${DBSNAP_DB}_before_restore" taken
  taken="$(sed -n 's/^taken=//p' "$DBSNAP_DIR/pending.info" 2>/dev/null)"
  if dbsnap_seed_changed; then
    echo "== the after-startup seed changed since the snapshot of ${taken:-?}: a fresh database instead, filled by the current seed (MDL_DB_RESET=${DBSNAP_MODE})"
    dbsnap_fresh || return 0
    dbsnap_session > "$DBSNAP_DIR/restored.session" 2>/dev/null
    echo "   the app runs on its seed data alone; what the tests created is gone (the previous data is kept as the database ${old})"
    dbsnap_empty_note
    return 0
  fi
  if dbsnap_unchanged; then
    echo "== the data equals the snapshot of ${taken:-?} (fingerprint of the app's own tables): nothing to put back, no restart"
  else
    echo "== putting the data back to the snapshot of ${taken:-?}: what the tests created goes (MDL_DB_RESET=${DBSNAP_MODE})"
    dbsnap_swap || return 0
  fi
  # 4. Done: the previous database stays as <name>_before_restore until the next rollback, and the
  # last three snapshots stay in .mxcli/db-snapshot/ for a rollback by hand.
  mv "$DBSNAP_DIR/pending.dump" "$DBSNAP_DIR/restored-$(date '+%Y%m%d-%H%M%S').dump"
  ls -1t "$DBSNAP_DIR"/restored-*.dump 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done
  # The session that just had its rollback: the one running now. A snapshot left pending by an earlier
  # session that never reached DONE is still the one restored, but the session it was taken in is
  # not this one -- recording that one made the next gate here take a second snapshot (B2B, 2026-10-07).
  dbsnap_session > "$DBSNAP_DIR/restored.session" 2>/dev/null
  rm -f "$DBSNAP_DIR/pending.info" "$DBSNAP_DIR/pending.fp" "$DBSNAP_DIR/dirty"
  echo "   the data is back to ${taken:-the snapshot}, and the app runs on it; what the tests created is gone"
  echo "   (the previous data is kept as the database ${old})"
  dbsnap_empty_note
  return 0
}

# dbsnap_refresh [force] -- before the suite: an earlier run that did not end in DONE left the rows
# its tests created, and tests that need a free time slot or an empty list then clash with their own
# leftovers (a room-booking run deleted them by hand, 2026-10-13). The gate calls it at the start of a
# full run, `--reset-data` with force at any run. The snapshot stays pending: the next DONE restores
# it again. Costs one stop and boot (about 30 s), so only when a suite ran since the last restore.
dbsnap_refresh() {
  dbsnap_enabled || return 0
  if [ ! -f "$DBSNAP_DIR/pending.dump" ]; then
    [ "${1:-}" = "force" ] && echo "   --reset-data: no snapshot is pending, so there is nothing to put back (one is taken at this gate)"
    return 0
  fi
  # The seed changed since the snapshot: its rows would put the old seed back. A fresh database, filled
  # by the current seed, at a full gate and at --reset-data alike (the snapshot is retaken after the boot).
  if dbsnap_seed_changed; then
    echo "== the after-startup seed changed since the snapshot of $(sed -n 's/^taken=//p' "$DBSNAP_DIR/pending.info" 2>/dev/null): a fresh database, filled by the current seed, before the tests"
    dbsnap_fresh && echo "   the tests start on the seed's data alone; a new snapshot is taken now"
    return 0
  fi
  [ "${1:-}" = "force" ] || [ -f "$DBSNAP_DIR/dirty" ] || return 0
  # Not for --reset-data: that one asks for a restart, and gets it.
  if [ "${1:-}" != "force" ] && dbsnap_unchanged; then
    rm -f "$DBSNAP_DIR/dirty"
    echo "== the data already equals the snapshot (fingerprint of the app's own tables): no restart; the tests start on it"
    return 0
  fi
  echo "== putting the data back to the snapshot of $(sed -n 's/^taken=//p' "$DBSNAP_DIR/pending.info" 2>/dev/null) before the tests: an earlier run left its test rows"
  local started=$SECONDS
  dbsnap_swap && echo "   the tests start on the snapshot's data; the next DONE puts it back again"
  # A room-booking session added --reset-data to every --only run, passing ones too: 13 restarts,
  # 17 s each, after one test had clashed with leftovers (2026-10-13). The cost, where it is paid.
  [ "${1:-}" = "force" ] && echo "   --reset-data took $((SECONDS - started))s (a restart): add it once, after a test failed on rows an earlier run left -- not to every run"
  return 0
}

# dbsnap_mark_dirty -- after a suite ran: its rows stay until a restore.
dbsnap_mark_dirty() {
  dbsnap_enabled || return 0
  [ -f "$DBSNAP_DIR/pending.dump" ] && : > "$DBSNAP_DIR/dirty"
  return 0
}

# Boots the app in a subshell: ensure_app exits the gate when a boot fails.
dbsnap_boot() {
  ( BOOT=1; BASE_URL=""; ensure_app ) >/dev/null 2>&1
  answers "http://localhost:${APP_PORT:-8081}"
}

dbsnap_status() {
  if ! dbsnap_enabled; then
    echo "the database reset is off here (MDL_DB_RESET=off, Docker, or not a local PostgreSQL): no snapshot is taken"
    return 0
  fi
  if [ -f "$DBSNAP_DIR/pending.dump" ]; then
    echo "pending snapshot of $DBSNAP_DB, taken $(sed -n 's/^taken=//p' "$DBSNAP_DIR/pending.info" 2>/dev/null); restored after the next full DONE"
  elif [ "$DBSNAP_MODE" = "session" ] && [ -n "$(dbsnap_session)" ] && [ "$(cat "$DBSNAP_DIR/restored.session" 2>/dev/null)" = "$(dbsnap_session)" ]; then
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

# After a rollback: the app's own tables empty means the person opens an empty app. A session seeded
# its demo data only from a test's reset button, so the snapshot taken before the tests held none,
# and the DONE handed over an app with no customer and no invoice (InvoiceChaseG7, 2026-10-12).
# Counted rows, not pg_stat (a restored database has no statistics yet).
dbsnap_empty_note() {
  local module tables total=0 n table
  [ -n "${USER_MODULES:-}" ] || return 0
  for module in $USER_MODULES; do
    tables="$(dbsnap_pg psql -d "$DBSNAP_DB" -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE '$(printf '%s' "$module" | tr '[:upper:]' '[:lower:]')\$%'" 2>/dev/null)"
    for table in $tables; do
      n="$(dbsnap_pg psql -d "$DBSNAP_DB" -tAc "SELECT count(*) FROM \"$table\"" 2>/dev/null)"
      total=$(( total + ${n:-0} ))
    done
  done
  [ "$total" = "0" ] || return 0
  echo "   !! the app's own tables ($(echo $USER_MODULES)) are empty now: the person opens an app with no data."
  echo "      Seed the demo data in the after-startup microflow, only when its tables are empty -- not from"
  echo "      a test's reset button: the snapshot is taken before the tests, so seed data must exist by then."
}
