#!/usr/bin/env bash
# The done gate: everything "finished" means, in one command.
#
#   bash tests/gate.sh                    # suite + mx check + lint + coverage + naming
#   bash tests/gate.sh --only crud        # one script by name fragment, warm browser
#   bash tests/gate.sh --tests-only       # the suite alone
#   bash tests/gate.sh --boot-if-needed   # start the app first if nothing answers
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
# Env: BASE_URL (else 8081 then 8080, whichever answers), APP_PORT (8081),
#      SCRIPT_TIMEOUT (90s), BOOT_TIMEOUT (180s), RUNTIME_LOG, ADMIN_PORT,
#      ADMIN_PASSWORD, ALLOW_BUSY_SESSION, MDL_BOOT_COMMAND.
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

ONLY=""; TESTS_ONLY=0; BOOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --tests-only) TESTS_ONLY=1; shift ;;
    --boot-if-needed) BOOT=1; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

answers() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null)" = "200" ]; }

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
  local -a mx_args=(docker check -p "$MPR")
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
  local modules module out status=0
  modules="$("$MXCLI" -p "$MPR" --json -c "SHOW MODULES" 2>/dev/null \
    | "$PY" -c 'import json,sys
for row in json.load(sys.stdin):
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System","MyFirstModule"):
        print(row["Module"])' 2>/dev/null)"
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
  local modules module status=0 dumped=0
  modules="$("$MXCLI" -p "$MPR" --json -c "SHOW MODULES" 2>/dev/null \
    | "$PY" -c 'import json,sys
for row in json.load(sys.stdin):
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System","MyFirstModule"):
        print(row["Module"])' 2>/dev/null)"
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

# --- start the slow, independent work first ---------------------------------
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  ( check_mx;       echo $? > "$WORK/mx.status" ) &
  ( check_lint;     echo $? > "$WORK/lint.status" ) &
  ( check_coverage; echo $? > "$WORK/coverage.status" ) &
  ( check_naming;   echo $? > "$WORK/naming.status" ) &
  echo "== mx check, lint, coverage and naming started (they need no app; running while the suite does)"
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
  # where the tools exist -- this one is genuinely an extra.
  command -v pgrep >/dev/null 2>&1 || return 0
  # Oldest running runtime process wins; its start time is when the model was read.
  started="$(ps -o lstart= -p "$(pgrep -f 'runtimelauncher|mxbuild' | head -1)" 2>/dev/null)"
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
          " changes need a restart, or this run measures the old app" % gap)
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
  # --keep-open leaves the browser warm for the next call, which is the iterate
  # loop's saving; inside one run the runner already reuses it.
  out="$("$MXCLI" playwright verify "${targets[@]}" -p "$MPR" \
        --base-url "$BASE_URL" --timeout "$SCRIPT_TIMEOUT" --keep-open 2>&1)"
  status=$?
  printf '%s\n' "$out" | grep -E '^\s+(PASS|FAIL)|^\s+FAIL:|^Total:'

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
if [ ${#failures[@]} -gt 0 ]; then
  echo "   NOT DONE — failed: ${failures[*]}"
  exit 1
fi
echo "   DONE — every check passed"
