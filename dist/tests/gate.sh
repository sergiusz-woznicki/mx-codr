#!/usr/bin/env bash
# The done gate: everything "finished" means, in one command.
#
#   bash tests/gate.sh                    # suite + mx check + lint + coverage + naming
#   bash tests/gate.sh --only crud        # one script by name fragment, warm browser
#   bash tests/gate.sh --tests-only       # the suite alone
#   bash tests/gate.sh --boot-if-needed   # start the app first if nothing answers
#   bash tests/gate.sh --restart          # stop this project's runtime, boot it again, then gate
#   bash tests/gate.sh --no-cache         # re-run the four model checks even if nothing changed
#
# Why one command rather than four: each shell round trip in an agent session costs
# far more than the command inside it -- `mxcli oql` measured 0.02s against a 1.9s
# median for a shell call. A session that ran the suite, `mx check`, lint and the
# coverage checker separately spent most of that gate on the trips, not the checks.
#
# The three model checks need neither the app nor the browser, so they run *while*
# the suite runs: 25.5 + 9.0 + 1.7 + 1.0 serial becomes about max(25.5, 11.7).
# With --boot-if-needed they also run while the runtime is still booting.
#
# Every step runs even if another fails, so one call reports the whole picture.
# Exit code is 0 only when every step passed.
#
# The four model checks are cached on what they read: the model (size and mtime of
# the .mpr and every file under mprcontents/) plus each check's own inputs -- the
# lint rules, the test scripts, the checker. A re-run with nothing changed replays
# the last green result, marked "(cached HH:MM)". A failure is never cached.
#
# Env: BASE_URL (else 8081 then 8080, whichever answers), APP_PORT (8081),
#      SCRIPT_TIMEOUT (90s), BOOT_TIMEOUT (180s), RUNTIME_LOG, ADMIN_PORT,
#      ADMIN_PASSWORD, ALLOW_BUSY_SESSION, MDL_BOOT_COMMAND, MDL_GATE_CACHE=0,
#      SERVE_PORT (mxbuild's port, for a second app on one machine).
#
# MDL_BOOT_COMMAND replaces `mxcli run --local` under --boot-if-needed, for machines
# where that cannot boot. It is read from tests/harness.env like the rest.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
cd "$APP_DIR"
# mxcli.exe vs mxcli, python vs python3, GNU vs BSD mktemp -- see tests/portable.sh.
. "$HARNESS_DIR/portable.sh"
MPR="$(ls -1 *.mpr 2>/dev/null | head -1)"
[ -n "$MPR" ] || { echo "no .mpr in $APP_DIR" >&2; exit 2; }
SCRIPT_TIMEOUT="${SCRIPT_TIMEOUT:-90s}"
APP_PORT="${APP_PORT:-8081}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
WORK="$(mdl_tmpdir mdl-gate)"
trap 'rm -rf "$WORK"' EXIT

ONLY=""; TESTS_ONLY=0; BOOT=0; RESTART=0; USE_CACHE="${MDL_GATE_CACHE:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --tests-only) TESTS_ONLY=1; shift ;;
    --boot-if-needed) BOOT=1; shift ;;
    --restart) RESTART=1; BOOT=1; shift ;;
    --no-cache) USE_CACHE=0; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

answers() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null)" = "200" ]; }
GATE_START=$SECONDS

# This project's own modules -- read once, used by coverage, naming and the cache.
user_modules() {
  "$MXCLI" -p "$MPR" --json -c "SHOW MODULES" 2>/dev/null \
    | "$PY" -c 'import json,sys
for row in json.load(sys.stdin):
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System","MyFirstModule"):
        print(row["Module"])' 2>/dev/null
}
USER_MODULES=""
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then USER_MODULES="$(user_modules)"; fi

# --- the processes that are this project's app ---------------------------------
# Matched on the project, not on the program name: another app's runtime on the
# same machine (a second agent, a second checkout) is not this one's, and its
# start time says nothing about this model. Oldest first.
project_pids() {
  command -v pgrep >/dev/null 2>&1 || return 0
  { pgrep -f "runtimelauncher.*$APP_DIR" 2>/dev/null
    pgrep -f "mxcli(\.exe)? run .*$MPR" 2>/dev/null; } | sort -un
}
descendants() {   # every process under <pid>, deepest first
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do descendants "$child"; echo "$child"; done
}

# The database the app boots against. `mxcli run --local --ensure-db` provisions one
# through Docker; where there is no Docker there is usually a PostgreSQL already
# installed, and this is the same job done with psql. Windows keeps psql off the
# PATH, so the config may name it outright.
psql_binary() {
  if [ -n "${MDL_PSQL:-}" ] && [ -x "$MDL_PSQL" ]; then printf '%s\n' "$MDL_PSQL"; return 0; fi
  if command -v psql >/dev/null 2>&1; then printf 'psql\n'; return 0; fi
  local candidate
  for candidate in "/c/Program Files/PostgreSQL"/*/bin/psql.exe; do
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

ensure_database() {      # the non-container equivalent of --ensure-db
  [ -n "${MDL_DB_NAME:-}" ] || return 0
  local psql
  psql="$(psql_binary)" || {
    echo "   !! no psql found, so the database cannot be checked or created." >&2
    echo "      Install PostgreSQL, or set MDL_PSQL in tests/harness.env." >&2
    return 1
  }
  # MDL_DB_HOST is stored in mxcli's shape, host:port. psql wants them apart.
  local host="${MDL_DB_HOST:-127.0.0.1:5432}" port user="${MDL_DB_USER:-mendix}"
  port="${host##*:}"; host="${host%%:*}"
  case "$port" in ''|*[!0-9]*) port=5432 ;; esac
  export PGPASSWORD="${MDL_DB_PASSWORD:-mendix}"
  if "$psql" -w -h "$host" -p "$port" -U "$user" -d postgres -tAc \
       "SELECT 1 FROM pg_database WHERE datname='$MDL_DB_NAME'" 2>/dev/null | grep -q 1; then
    return 0
  fi
  echo "   creating database $MDL_DB_NAME"
  "$psql" -w -h "$host" -p "$port" -U "$user" -d postgres -c "CREATE DATABASE \"$MDL_DB_NAME\"" >/dev/null 2>&1
}

# --- the checks that need nothing but the .mpr -------------------------------
# Each writes one summary line and an exit status, so the parent can read the
# result after `wait` -- a background subshell cannot append to the parent's arrays.
check_mx() {
  local out
  # `docker check` is a misleading name: it runs Mendix's own `mx`, and with
  # --mxbuild-path it runs the one inside a Studio Pro installation. That is the
  # whole of the no-Docker mode for this check -- see tests/harness.env.
  #
  # It runs on a COPY of the model, never the live tree. `mx check` saves the .mpr
  # it checks (update-widgets runs first) -- bytes identical, mtime new -- and under
  # `mxcli run --watch` that mtime is the reload trigger. Checking the live tree
  # therefore restarted the runtime in the middle of the suite: a red test with no
  # cause, and a "model changed after the runtime started" warning that sent one
  # session into two needless restarts. What the copy needs, measured on
  # InvoiceDesk: the .mpr, mprcontents/, widgets/ (update-widgets reads them) and
  # theme/ + themesource/ (897 false CE6083 "not supported by your theme" errors
  # without them); javasource/ rides along when present; userlib/ and resources/
  # are not read. On APFS `cp -c` clones, so 25MB costs ~0.2s.
  local scratch="$WORK/mxcheck" item
  mkdir -p "$scratch"
  for item in "$MPR" mprcontents widgets theme themesource javasource; do
    [ -e "$item" ] || continue
    cp -Rc "$item" "$scratch/" 2>/dev/null || cp -R "$item" "$scratch/" 2>/dev/null || {
      echo "mx check: could not copy $item to a scratch directory" > "$WORK/mx.summary"; return 1; }
  done
  local -a mx_args=(docker check -p "$scratch/$MPR")
  [ -n "${MDL_MXBUILD_PATH:-}" ] && mx_args+=(--mxbuild-path "$MDL_MXBUILD_PATH")
  out="$("$MXCLI" "${mx_args[@]}" 2>&1)"
  local errors
  # `mx check` exits 0 even with model errors, so read the count it prints.
  errors="$(printf '%s\n' "$out" | grep -oE 'contains: [0-9]+ errors' | grep -oE '[0-9]+' | tail -1)"
  if [ -z "$errors" ]; then
    printf '%s\n' "$out" | tail -3 > "$WORK/mx.detail"
    if [ -n "${MDL_MXBUILD_PATH:-}" ]; then
      # Almost always the same cause: `mx` came from a Studio Pro whose version does
      # not match this project. Say that rather than leaving a bare "no count".
      echo "   (using $MDL_MXBUILD_PATH -- it must match this project's Mendix version)" \
        >> "$WORK/mx.detail"
    fi
    echo "mx check: did not report a count" > "$WORK/mx.summary"; return 1
  fi
  echo "mx check: $errors errors" > "$WORK/mx.summary"
  [ "$errors" = "0" ] && return 0
  printf '%s\n' "$out" | grep -E '^\[error\]|error' | head -10 > "$WORK/mx.detail"
  return 1
}

check_lint() {
  local out line errors
  out="$("$MXCLI" lint -p "$MPR" 2>&1)"
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ issues:' | tail -1)"
  echo "lint: ${line:-no summary line}" > "$WORK/lint.summary"
  errors="$(printf '%s\n' "$line" | grep -oE '[0-9]+ errors' | grep -oE '[0-9]+')"
  # Warnings and info are for a human to weigh; only errors gate.
  [ -n "$errors" ] && [ "$errors" != "0" ] || return 0
  printf '%s\n' "$out" | grep -E '✖|\[error\]' | head -10 > "$WORK/lint.detail"
  return 1
}

check_coverage() {
  [ -f tools/mdl-checks/check_test_coverage.py ] || { : > "$WORK/coverage.summary"; return 0; }
  local modules="$USER_MODULES" module out status=0
  [ -n "$modules" ] || { echo "coverage: no user module found" > "$WORK/coverage.summary"; return 0; }
  : > "$WORK/coverage.summary"; : > "$WORK/coverage.detail"
  for module in $modules; do
    out="$("$PY" tools/mdl-checks/check_test_coverage.py . "$module" 2>&1)" || status=1
    echo "coverage $module: $(printf '%s\n' "$out" | tail -1)" >> "$WORK/coverage.summary"
    printf '%s\n' "$out" | grep -vE '^(PASS|FAIL)' | head -10 >> "$WORK/coverage.detail"
  done
  return $status
}

# The naming rules -- captions on decisions and on every action, real variable
# names, no stacked positions -- live in check_mdl.py, which reads MDL text rather
# than the model catalog. Nothing ran it before, so those rules were documentation
# an agent could skip without the gate noticing. `describe module` is ground truth:
# it is what actually landed in the .mpr, not what a script file claimed.
check_naming() {
  [ -f tools/mdl-checks/check_mdl.py ] || { : > "$WORK/naming.summary"; return 0; }
  local modules="$USER_MODULES" module status=0 dumped=0
  [ -n "$modules" ] || { echo "naming: no user module found" > "$WORK/naming.summary"; return 0; }
  # `describe module` emits the module and its roles only -- the documents have to be
  # enumerated and described one by one. Thirteen microflows cost well under a second.
  mkdir -p "$WORK/mdl"
  for module in $modules; do
    for kind in MICROFLOWS NANOFLOWS; do
      "$MXCLI" -p "$MPR" --json -c "SHOW $kind IN $module" 2>/dev/null \
        | "$PY" -c 'import json,sys
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for row in rows:
    name = row.get("Qualified Name") or row.get("QualifiedName")
    if name:
        print(name)' 2>/dev/null | while read -r document; do
          "$MXCLI" describe "${kind%S}" "$document" -p "$MPR" >> "$WORK/mdl/$module.mdl" 2>/dev/null
        done
    done
    [ -s "$WORK/mdl/$module.mdl" ] && dumped=$((dumped + 1))
  done
  if [ "$dumped" = "0" ]; then
    echo "naming: could not describe any module" > "$WORK/naming.summary"; return 0
  fi
  local out
  out="$("$PY" tools/mdl-checks/check_mdl.py "$WORK/mdl" --skill naming 2>&1)" || status=1
  echo "naming: $(printf '%s\n' "$out" | head -1)" > "$WORK/naming.summary"
  printf '%s\n' "$out" | grep -E '^\s+- ' | head -10 > "$WORK/naming.detail"
  return $status
}

# --- caching the model checks --------------------------------------------------
# A check's key is a digest of every input it reads: the model (size + mtime of the
# .mpr and of each file under mprcontents/ -- bytes would cost 15MB of hashing per
# check, and the mtime is honest now that `mx check` runs on a copy) and the
# check's own extras. Only a passing result is stored, so a cached line is always a
# line that was green when it ran; a red check runs again every time until fixed.
fingerprint() {   # fingerprint <path>... -> one digest line
  "$PY" - "$MPR" mprcontents "$@" <<'PY_FP'
import hashlib, os, sys
h = hashlib.sha256()
def add(path):
    try:
        st = os.stat(path)
    except OSError:
        h.update(("missing %s\n" % path).encode()); return
    if os.path.isdir(path):
        for root, dirs, files in os.walk(path):
            dirs.sort()
            for name in sorted(files):
                add(os.path.join(root, name))
    else:
        h.update(("%s %d %d\n" % (path, st.st_size, st.st_mtime_ns)).encode())
for path in sys.argv[1:]:
    add(path)
print(h.hexdigest()[:24])
PY_FP
}
CACHE_DIR="$APP_DIR/.mxcli/gate-cache"
# run_cached <name> <function> <extra input paths...>
run_cached() {
  local name="$1" fn="$2" key="" status; shift 2
  if [ "$USE_CACHE" = "1" ]; then
    key="$(fingerprint "$@" 2>/dev/null)"
    if [ -n "$key" ] && [ -f "$CACHE_DIR/$name.key" ] && [ "$(cat "$CACHE_DIR/$name.key")" = "$key" ] \
       && [ -f "$CACHE_DIR/$name.summary" ]; then
      sed "s/\$/ (cached $(date -r "$CACHE_DIR/$name.summary" +%H:%M 2>/dev/null || echo earlier))/" \
        "$CACHE_DIR/$name.summary" > "$WORK/$name.summary"
      : > "$WORK/$name.detail"
      echo 0 > "$WORK/$name.status"
      return 0
    fi
  fi
  local started=$SECONDS
  "$fn"; status=$?
  echo $((SECONDS - started)) > "$WORK/$name.secs"
  echo "$status" > "$WORK/$name.status"
  if [ "$status" = "0" ] && [ -n "$key" ] && mkdir -p "$CACHE_DIR" 2>/dev/null; then
    cp "$WORK/$name.summary" "$CACHE_DIR/$name.summary" 2>/dev/null && echo "$key" > "$CACHE_DIR/$name.key"
  fi
  return "$status"
}

# --- start the slow, independent work first ---------------------------------
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  ( run_cached mx       check_mx       widgets theme themesource javasource ) &
  ( run_cached lint     check_lint     .claude/lint-rules ) &
  ( run_cached coverage check_coverage tests tools/mdl-checks/check_test_coverage.py ) &
  ( run_cached naming   check_naming   tools/mdl-checks/check_mdl.py ) &
  echo "== mx check, lint, coverage and naming started (they need no app; running while the suite does)"
fi

# --- --restart: this project's app, stopped and booted again -------------------
# What an agent did by hand eleven times in one session, with pgrep and kill and a
# port that would not free. The kill goes to the process tree under `mxcli run`
# (SIGTERM to mxcli alone orphans mxbuild and the Java runtime, which then hold
# the ports), then to any runtime still serving this project's deployment.
if [ "$RESTART" = "1" ]; then
  echo "== restarting this project's app"
  victims=""
  for pid in $(project_pids); do victims="$victims $(descendants "$pid") $pid"; done
  if [ -n "${victims// /}" ]; then
    # shellcheck disable=SC2086
    kill -TERM $victims 2>/dev/null || true
    waited=0
    while [ "$waited" -lt 15 ] && [ -n "$(project_pids)" ]; do sleep 1; waited=$((waited + 1)); done
    # shellcheck disable=SC2086
    [ -z "$(project_pids)" ] || kill -KILL $victims 2>/dev/null || true
    sleep 1
    echo "   stopped:$victims"
  else
    echo "   nothing of this project was running"
  fi
  # Whatever answered on the port belonged to the old runtime; the boot below
  # must not adopt it.
  BASE_URL=""
fi

# --- the app ------------------------------------------------------------------
if [ -z "${BASE_URL:-}" ]; then
  for candidate in "http://localhost:$APP_PORT" http://localhost:8080; do
    answers "$candidate" && { BASE_URL="$candidate"; break; }
  done
fi
if [ -z "${BASE_URL:-}" ] || ! answers "$BASE_URL"; then
  if [ "$BOOT" = "1" ]; then
    # An orphaned `mxbuild --serve` from a killed run holds port 6543, and mxcli
    # refuses to adopt it -- correctly, since a stale build server makes edits look
    # like they do nothing. Say so before the boot fails, because the symptom
    # otherwise is an app that simply never answers.
    if command -v pgrep >/dev/null 2>&1 && pgrep -f 'mxbuild' >/dev/null 2>&1; then
      echo "   !! an mxbuild process is already running. If this boot fails on"
      echo "      'port 6543 (mxbuild serve) is already in use', it is an orphan:"
      echo "      pgrep -af 'mxbuild|runtimelauncher'   then kill that pid"
    fi
    # A project may have to boot some other way. On Windows `mxcli run --local` fails
    # in three places before it ever reaches the app, all of them invisible: mxbuild
    # splits --java-home on spaces and exits printing usage; the mxbuild cache has no
    # gradle-8.5, so Java compilation dies with "No supported Gradle installation
    # found"; and mxcli's own liveness probe is Process.Signal(0), which Windows
    # rejects for every signal but Kill, so a healthy mxbuild and a healthy runtime
    # both read as "exited during startup" on the first poll. install.sh fixes the
    # first two; the third needs a patched mxcli (mxcli-windows-serve-fix.patch).
    # Until that lands, put a working boot command in MDL_BOOT_COMMAND
    # (tests/harness.env) and the gate uses it instead.
    if [ -n "${MDL_BOOT_COMMAND:-}" ]; then
      echo "== no app answering; booting with MDL_BOOT_COMMAND"
      ensure_database || true
      ( eval "$MDL_BOOT_COMMAND" > .mxcli/gate-boot.log 2>&1 & )
      BASE_URL="http://localhost:$APP_PORT"
      waited=0
      until answers "$BASE_URL"; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
          echo "the app did not answer within ${BOOT_TIMEOUT}s; last lines of .mxcli/gate-boot.log:" >&2
          tail -15 .mxcli/gate-boot.log >&2
          exit 2
        fi
      done
      echo "   up after ${waited}s"
      booted_by_command=1
    fi
    if [ -z "${booted_by_command:-}" ]; then
    echo "== no app answering; booting $MPR on port $APP_PORT with hot reload"
    boot_args=(run --local -p "$MPR" --app-port "$APP_PORT" --watch)
    # A second app on the same machine (another agent, another checkout) needs its
    # own admin and mxbuild ports too, or the boot fails on a port the other holds.
    [ -n "${ADMIN_PORT:-}" ] && boot_args+=(--admin-port "$ADMIN_PORT")
    [ -n "${SERVE_PORT:-}" ] && boot_args+=(--serve-port "$SERVE_PORT")
    if [ -n "${MDL_DB_NAME:-}" ]; then
      ensure_database || true
      boot_args+=(--db-name "$MDL_DB_NAME")
      [ -n "${MDL_DB_HOST:-}" ] && boot_args+=(--db-host "$MDL_DB_HOST")
      [ -n "${MDL_DB_USER:-}" ] && boot_args+=(--db-user "$MDL_DB_USER")
      [ -n "${MDL_DB_PASSWORD:-}" ] && boot_args+=(--db-password "$MDL_DB_PASSWORD")
    fi
    ( "$MXCLI" "${boot_args[@]}" > .mxcli/gate-boot.log 2>&1 & )
    BASE_URL="http://localhost:$APP_PORT"
    waited=0
    until answers "$BASE_URL"; do
      perl -e 'select undef, undef, undef, 1' 2>/dev/null || sleep 1
      waited=$((waited + 1))
      if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
        echo "the app did not answer within ${BOOT_TIMEOUT}s; last lines of .mxcli/gate-boot.log:" >&2
        tail -15 .mxcli/gate-boot.log >&2
        exit 2
      fi
    done
    echo "   up after ${waited}s"
    fi
  else
    cat >&2 <<MSG
no app answering on ${BASE_URL:-http://localhost:$APP_PORT or :8080}. Start it, ideally with
hot reload so page and microflow changes need no restart:

  ${MDL_BOOT_COMMAND:-$MXCLI run --local -p $MPR --app-port $APP_PORT --watch}

or re-run this with --boot-if-needed.
MSG
    exit 2
  fi
fi

# A developer/trial licence caps concurrent sessions -- measured on this runtime, the
# 7th live session was refused, and every leftover test browser, CLI login and open
# developer tab counts towards it. Nine scripts that all fail on a refused sign-in
# look like nine broken features, so say what the runtime is holding, and stop
# outright if it has already started refusing.
#
# Note m2ee reports distinct signed-in *users*, not sessions: four logins as one user
# show up as one name. So the user list is a hint, and the runtime log is the fact.
preflight_session() {
  local log="${RUNTIME_LOG:-$APP_DIR/.mxcli/runtime.log}"
  local users
  users="$(curl -s -m 5 -X POST "http://localhost:${ADMIN_PORT:-8090}/" \
      -H "X-M2EE-Authentication: $(printf '%s' "${ADMIN_PASSWORD:-mxcli-local-dev}" | base64)" \
      -H 'Content-Type: application/json' -d '{"action":"get_logged_in_user_names"}' 2>/dev/null \
    | "$PY" -c 'import json,sys
try:
    f = json.load(sys.stdin).get("feedback", {})
except Exception:
    sys.exit(0)
users = f.get("users") or []
if users:
    print(",".join(users))' 2>/dev/null)"
  [ -n "$users" ] && echo "   already signed in: $users"

  # A refusal in the last two minutes is about now, not about last week.
  local refusal=""
  if [ -f "$log" ]; then
    refusal="$(tail -400 "$log" 2>/dev/null | grep 'Maximum number of sessions exceeded' | tail -1 \
      | "$PY" -c "
import datetime, re, sys
line = sys.stdin.read().strip()
stamp = re.match(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', line) if line else None
if not stamp:
    sys.exit(0)
when = datetime.datetime.strptime(stamp.group(1), '%Y-%m-%d %H:%M:%S')
if (datetime.datetime.now() - when).total_seconds() <= 120:
    print(stamp.group(1))" 2>/dev/null)"
  fi
  [ -n "$refusal" ] || return 0
  if [ "${ALLOW_BUSY_SESSION:-0}" = "1" ]; then
    echo "   the runtime refused a session at $refusal -- running anyway (ALLOW_BUSY_SESSION=1)"
    return 0
  fi
  cat >&2 <<MSG
the runtime refused a session at $refusal:
  "Maximum number of sessions exceeded! (You are currently using a trial license)"
Every test that signs in will fail the same way, and the failure looks like a broken
feature. Close leftover browsers and developer tabs, wait for the sessions to time
out, or restart the runtime -- then run this again. ALLOW_BUSY_SESSION=1 runs anyway.
MSG
  exit 2
}

# Security and entity changes do not hot-apply: the runtime keeps serving the model
# it booted with, so a correct fix reads as a failing feature. Observed twice in one
# session -- a portal test reported "shows 10 invoices, owns 4" until the restart,
# then reported 3.
preflight_stale_model() {
  local started

  # Primary signal: file dates, because they work everywhere.
  #
  # This check used to depend entirely on pgrep, which Git Bash does not have -- so
  # on Windows it returned 0 and said nothing, every time. That is the worst kind of
  # degradation: the gate still goes green while measuring a stale build. Caught in
  # the field with a .mpr ~25 minutes newer than the deployment the runtime was
  # serving.
  #
  # Where the runtime serves a built deployment there is no hot reload at all, so an
  # MDL change is invisible until a rebuild. Comparing the .mpr against the built
  # model catches exactly that, with no process tools involved.
  # Under `mxcli run --watch` the watcher applies most model changes itself and
  # reports so in the boot log; a change it has applied is not stale. The log's
  # last line is the watcher's last word: "build #N applied via reload" means the
  # runtime serves the model as it is now, and both signals below stay quiet.
  local boot_log="$APP_DIR/.mxcli/gate-boot.log"
  if [ -f "$boot_log" ] && [ ! "$MPR" -nt "$boot_log" ] \
     && tail -1 "$boot_log" 2>/dev/null | grep -q 'applied via reload'; then
    return 0
  fi

  local built
  for built in deployment/model/model.mdp deployment/model/metadata.json; do
    [ -f "$built" ] || continue
    "$PY" - "$MPR" "$built" <<'PY_BUILT'
import os, sys
mpr, built = sys.argv[1], sys.argv[2]
try:
    gap = int(os.path.getmtime(mpr) - os.path.getmtime(built))
except OSError:
    sys.exit(0)
if gap > 5:
    print("   !! the model is %ds newer than the built deployment -- this run measures"
          " the OLD app" % gap)
    print("      rebuild before trusting anything green here")
PY_BUILT
    break
  done

  # Secondary signal: the runtime's own start time, which also catches a deployment
  # that was rebuilt while the runtime kept serving the model it booted with. Only
  # where the tools exist -- this one is genuinely an extra. This project's
  # processes only: another app's runtime on the machine says nothing about this
  # model, and matching on the program name alone once reported "changed 1426s
  # after the runtime started" about a runtime that was serving a different app.
  command -v pgrep >/dev/null 2>&1 || return 0
  # Oldest running runtime process wins; its start time is when the model was read.
  local oldest
  oldest="$(project_pids | head -1)"
  [ -n "$oldest" ] || return 0
  started="$(ps -o lstart= -p "$oldest" 2>/dev/null)"
  [ -n "$started" ] || return 0
  "$PY" - "$MPR" "$started" <<'PY_STALE'
import datetime, os, sys
mpr, started = sys.argv[1], sys.argv[2]
try:
    boot = datetime.datetime.strptime(" ".join(started.split()), "%a %b %d %H:%M:%S %Y")
except ValueError:
    sys.exit(0)
changed = datetime.datetime.fromtimestamp(os.path.getmtime(mpr))
gap = (changed - boot).total_seconds()
if gap > 5:
    print("   !! the model changed %ds after the runtime started -- security and entity"
          " changes need a restart, or this run measures the old app:" % gap)
    print("      bash tests/gate.sh --restart")
PY_STALE
}

# Two machine-level facts worth knowing before nine scripts fail on them. Both are
# instant: the browser path is a file test, the security level a model read.
preflight_environment() {
  local config="$APP_DIR/.playwright/cli.config.json"
  if [ -f "$config" ]; then
    local browser
    browser="$("$PY" -c "
import json, os, sys
try:
    options = json.load(open('$config'))['browser']['launchOptions']
except Exception:
    sys.exit(0)
path = options.get('executablePath')
if path and not os.path.exists(path):
    print(path)
" 2>/dev/null)"
    if [ -n "$browser" ]; then
      echo "   !! the browser binary in .playwright/cli.config.json does not exist: $browser"
      echo "      every test will fail with 'opening browser: exit status 1' -- re-run the"
      echo "      skillpack installer, which repoints it at an installed headless shell"
    fi
  fi

  # With security on, tests must sign in; without credentials they all fail the same
  # way, and the failure reads as nine broken features.
  if [ -z "${TEST_PASSWORD:-}" ] && [ ! -f "$APP_DIR/tests/credentials.env" ]; then
    local level
    level="$("$MXCLI" -p "$MPR" -c "SHOW PROJECT SECURITY" 2>/dev/null | grep -i 'Security Level' | head -1)"
    case "$level" in
      *Off*|"") ;;
      *) echo "   !! $level, but tests/credentials.env is missing -- tests that sign in will"
         echo "      fail on the login page. Create it: TEST_USER=... and TEST_PASSWORD=..." ;;
    esac
  fi
}

failures=()
summary=()

# A test that has never failed may assert nothing at all, and nothing about its
# text says which. So the gate keeps the record: the first red run of a script,
# under --only, leaves .mxcli/red-first/<script>. A script that goes green under
# --only with no such record is named once -- and only then is it worth breaking
# the feature on purpose to see the test notice. Breaking every feature for every
# test, as one session did, cost 15 minutes and proved what the red-first run had
# already proved.
record_red_first() {
  [ -n "$ONLY" ] || return 0
  local out="$1" dir="$APP_DIR/.mxcli/red-first" line name verdict
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$out" | grep -E '^\s+(PASS|FAIL)\s' | while read -r verdict name _; do
    name="${name%.test.sh}"
    case "$verdict" in
      FAIL) [ -f "$dir/$name" ] || date '+%Y-%m-%d %H:%M' > "$dir/$name" ;;
      PASS)
        if [ ! -f "$dir/$name" ] && [ ! -f "$dir/$name.green" ]; then
          date '+%Y-%m-%d %H:%M' > "$dir/$name.green"
          echo "   !! $name went green without ever being red here. A test that has never"
          echo "      failed may assert nothing: break the feature once (an mxcli exec that"
          echo "      changes the message, say) and watch this same command go red, then undo it."
        fi ;;
    esac
  done
}

step_tests() {
  local targets=("tests/")
  if [ -n "$ONLY" ]; then
    targets=()
    for script in tests/verify-*"$ONLY"*.test.sh; do
      [ -f "$script" ] && targets+=("$script")
    done
    [ ${#targets[@]} -gt 0 ] || { echo "no test matches '$ONLY'" >&2; exit 2; }
  fi
  echo "== tests: ${targets[*]}"
  local out status line
  # The scripts inherit what is exported and nothing else. PY and MXCLI save each
  # of them a Python probe; BASE_URL is the app the gate found, which lib.sh would
  # otherwise default to :8081; SCRIPT_TIMEOUT sizes lib.sh's own watchdog to fire
  # just before the runner's kill would.
  export PY MXCLI BASE_URL SCRIPT_TIMEOUT
  # Sessions: a full run signs in once and out once (MDL_SESSION_REUSE, see
  # lib.sh); an --only loop leaves the session signed in between iterations
  # (KEEP_SESSION), so the next run of the same script skips the sign-in. Either
  # way the licence sees one session, not one per script.
  if [ -n "$ONLY" ]; then
    export KEEP_SESSION="${KEEP_SESSION:-1}"
  else
    export MDL_SESSION_REUSE="${MDL_SESSION_REUSE:-1}"
  fi
  # --keep-open leaves the browser warm for the next call, which is the iterate
  # loop's saving; inside one run the runner already reuses it.
  local started=$SECONDS
  out="$("$MXCLI" playwright verify "${targets[@]}" -p "$MPR" \
        --base-url "$BASE_URL" --timeout "$SCRIPT_TIMEOUT" --keep-open 2>&1)"
  status=$?
  echo $((SECONDS - started)) > "$WORK/tests.secs"
  printf '%s\n' "$out" | grep -E '^\s+(PASS|FAIL)|^\s+FAIL:|^Total:'
  record_red_first "$out"
  # The one sign-out for the whole run. Not under --only: that session is the
  # next iteration's saving, and the full gate ends it.
  if [ -z "$ONLY" ] && [ "${KEEP_SESSION:-0}" != "1" ]; then
    ( . tests/lib.sh >/dev/null 2>&1; release_session ) 2>/dev/null
  fi

  # A dead app or a closed browser fails every script that touches it, and those
  # failures read exactly like broken features -- one session rewrote model access
  # rules to chase five of them. Name the cause instead.
  local environment=""
  case "$out" in
    *ERR_CONNECTION_REFUSED*|*ECONNREFUSED*)
      environment="the app stopped answering on $BASE_URL during the run (a model change that cannot hot-apply stops the runtime; restart it, or use --boot-if-needed)" ;;
    *"browser has been closed"*|*"Target page, context or browser has been closed"*)
      environment="the browser was closed while the suite was running (playwright-cli has one shared browser -- another session or command closed it)" ;;
    *"opening browser: exit status"*)
      environment="the browser could not be started (check .playwright/cli.config.json executablePath, then: playwright-cli close && playwright-cli open)" ;;
  esac
  if [ -n "$environment" ]; then
    echo "   !! not a feature failure: $environment"
  fi

  line="$(printf '%s\n' "$out" | grep -E '^Total:' | tail -1)"
  if [ -n "$line" ]; then
    if [ -n "$environment" ]; then
      summary+=("tests: $line -- ENVIRONMENT, not the feature: $environment")
    else
      summary+=("tests: $line")
    fi
  else
    # No Total line means the runner never ran the scripts -- "Error: opening
    # browser: exit status 1", an unreachable app, a bad flag. Reporting "no result"
    # hides the one sentence that explains it and costs a whole round trip.
    local why
    why="$(printf '%s\n' "$out" | grep -iE '^error|error:|panic|unknown flag|no such file' | tail -1)"
    [ -n "$why" ] || why="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
    echo "   the runner produced no results: $why"
    summary+=("tests: no result -- ${environment:-${why:-the runner printed nothing}}")
  fi
  if [ "$status" != "0" ]; then
    failures+=("tests")
    # The facts a red test raises -- how many rows exist, who is signed in, what the
    # access rules allow -- cost 0.2s and answer most of them. Print them here rather
    # than leaving someone to remember diagnose.sh exists; three sessions did not.
    if [ -z "$environment" ] && [ -x tests/diagnose.sh ]; then
      echo "== facts (tests/diagnose.sh)"
      bash tests/diagnose.sh 2>&1 | sed 's/^/   /' | head -40
    fi
  fi
}

collect() {
  local name="$1" label="$2"
  [ -f "$WORK/$name.status" ] || return 0
  local status
  status="$(cat "$WORK/$name.status")"
  if [ -s "$WORK/$name.summary" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && summary+=("$line")
    done < "$WORK/$name.summary"
  fi
  if [ "$status" != "0" ]; then
    [ -s "$WORK/$name.detail" ] && { echo "== $label"; cat "$WORK/$name.detail"; }
    failures+=("$label")
  fi
}

preflight_session
preflight_environment
preflight_stale_model
step_tests
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  wait
  collect mx "mx check"
  collect lint "lint"
  collect coverage "coverage"
  collect naming "naming"
fi

echo
echo "== gate"
for line in "${summary[@]}"; do echo "   $line"; done
timing=""
for name in tests mx lint coverage naming; do
  [ -f "$WORK/$name.secs" ] && timing="$timing $name $(cat "$WORK/$name.secs")s,"
done
echo "   timing:${timing} wall $((SECONDS - GATE_START))s"
if [ ${#failures[@]} -gt 0 ]; then
  echo "   NOT DONE — failed: ${failures[*]}"
  exit 1
fi
echo "   DONE — every check passed"
