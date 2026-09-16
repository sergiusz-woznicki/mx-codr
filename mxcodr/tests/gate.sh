#!/usr/bin/env bash
# tests/gate.sh -- the done gate: everything "finished" means, in one command.
#
#   bash tests/gate.sh                    # suite + mx check + lint + coverage + naming + layout
#   bash tests/gate.sh --only crud        # one script by name fragment, warm browser
#   bash tests/gate.sh --tests-only       # the suite alone
#   bash tests/gate.sh --boot-if-needed   # start the app first if nothing answers
#   bash tests/gate.sh --restart          # stop this project's runtime, boot it again, then gate
#   bash tests/gate.sh --no-cache         # re-run the five model checks even if nothing changed
#
# Six verdicts: the browser suite (tests/verify-*.test.sh) and five model checks that
# need no app -- mx check, lint, coverage, naming, layout. Every step runs even if
# another fails; a passing model check is replayed while its inputs are unchanged.
#   DONE — every check passed               exit 0
#   NOT DONE — failed: <checks>             exit 1
#   NOT DONE — could not run: <checks>      exit 2
# Exit 2 also means the gate stopped early: no .mpr, bad argument, no app answering,
# a boot that failed, or the runtime refusing sessions.
#
# Env: BASE_URL (else 8081 then 8080), APP_PORT (8081), SCRIPT_TIMEOUT (90s),
#      BOOT_TIMEOUT (180s), RUNTIME_LOG, ADMIN_PORT, ADMIN_PASSWORD, SERVE_PORT,
#      ALLOW_BUSY_SESSION=1, MDL_GATE_CACHE=0, MDL_BOOT_COMMAND (replaces mxcli run),
#      MDL_MXBUILD_PATH, MDL_DB_NAME/HOST/USER/PASSWORD, MDL_PSQL -- the MDL_* ones
#      may also be set in tests/harness.env.
# Lines 2-24 are printed by --help; keep them 23 lines.

# Sections (2-4, 8 and 9 only define functions):
#   1. Setup          find the .mpr, source portable.sh, parse flags
#   2. App helpers    answers, boot failure, wait_for_boot, user modules, pids, database
#   3. Model checks   check_mx, check_lint, check_coverage, check_naming, check_layout
#   4. Cache          fingerprint, run_cached
#   5. Start checks   the five model checks, in the background
#   6. --restart      stop this project's app
#   7. The app        find it, or boot it
#   8. Preflights     sessions, stale model, environment
#   9. Tests          result arrays, record_red_first, step_tests
#  10. Run            preflights, suite, wait, collect
#  11. Summary        verdict lines, DONE / NOT DONE, exit code
# No -e: a failing step must not end the gate.
set -uo pipefail

# --- 1. Setup ---
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
cd "$APP_DIR"
. "$HARNESS_DIR/portable.sh"
MPR="$(ls -1 *.mpr 2>/dev/null | head -1)"
[ -n "$MPR" ] || { echo "no .mpr in $APP_DIR" >&2; exit 2; }
# The name ends up in a pgrep pattern whose matches get killed: safe characters only.
case "$MPR" in
  *[!A-Za-z0-9._-]*|-*|.*)
    echo "refusing to run: the .mpr name must be letters, digits, dot, dash or underscore: $MPR" >&2
    exit 2 ;;
esac
if [ "$(ls -1 *.mpr 2>/dev/null | wc -l | tr -d ' ')" != "1" ]; then
  echo "   !! more than one .mpr here; using $MPR. Remove the others, or name one with MPR=." >&2
fi
SCRIPT_TIMEOUT="${SCRIPT_TIMEOUT:-90s}"
APP_PORT="${APP_PORT:-8081}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
# Scratch directory for this run's result files; removed on exit.
WORK="$(mdl_tmpdir mdl-gate)"
trap 'rm -rf "$WORK"' EXIT

ONLY=""; TESTS_ONLY=0; BOOT=0; RESTART=0; USE_CACHE="${MDL_GATE_CACHE:-1}"
booted_by_command=""   # set to 1 once MDL_BOOT_COMMAND has booted the app
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

# --- 2. App helpers ---
answers() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null)" = "200" ]; }

# True when the boot log already shows a failure, so the wait loop stops early.
boot_failed() {   # boot_failed <log>
  [ -f "$1" ] || return 1
  grep -qE '^Error:|initial build failed|cannot be deployed, because it contains errors|is already in use|exited during startup|BUILD FAILED' "$1" 2>/dev/null
}
report_boot_failure() {   # report_boot_failure <log> <waited>
  echo "the app did not start (${2}s): the boot reported an error rather than coming up" >&2
  grep -E '^Error:|\[CE[0-9]+\]|initial build failed|is already in use|exited during startup' "$1" 2>/dev/null \
    | head -12 >&2
  echo "   full log: $1" >&2
  exit 2
}
# Polls $BASE_URL once a second until it answers, then prints how long it took.
# Exits 2 when <log> shows a boot error or BOOT_TIMEOUT seconds pass.
wait_for_boot() {   # wait_for_boot <log>
  local log="$1" waited=0
  until answers "$BASE_URL"; do
    perl -e 'select undef, undef, undef, 1' 2>/dev/null || sleep 1
    waited=$((waited + 1))
    boot_failed "$log" && report_boot_failure "$log" "$waited"
    if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
      echo "the app did not answer within ${BOOT_TIMEOUT}s; last lines of $log:" >&2
      tail -15 "$log" >&2
      exit 2
    fi
  done
  echo "   up after ${waited}s"
}
GATE_START=$SECONDS

# This project's own modules (not System, MyFirstModule or marketplace); 2 if unreadable.
user_modules() {
  local listing
  listing="$("$MXCLI" -p "$MPR" --json -c "SHOW MODULES" 2>/dev/null)" || return 2
  printf '%s' "$listing" | "$PY" -c 'import json,sys
rows = json.load(sys.stdin)
if not isinstance(rows, list):
    sys.exit(1)
for row in rows:
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System","MyFirstModule"):
        print(row["Module"])' 2>/dev/null || return 2
}
# USER_MODULES_READ=0 tells a failed SHOW MODULES apart from a project with no module.
USER_MODULES=""; USER_MODULES_READ=1
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  USER_MODULES="$(user_modules)" || USER_MODULES_READ=0
fi

# PIDs of this project's runtime and `mxcli run`, matched on the project path; oldest first.
project_pids() {
  command -v pgrep >/dev/null 2>&1 || return 0
  { pgrep -f "runtimelauncher.*$APP_DIR" 2>/dev/null
    pgrep -f "mxcli(\.exe)? run .*$(mdl_ere_quote "$MPR")" 2>/dev/null; } | sort -un
}
descendants() {   # every process under <pid>, deepest first
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do descendants "$child"; echo "$child"; done
}

# Prints the psql to use (MDL_PSQL, PATH, Program Files); returns 1 if none.
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
  # MDL_DB_HOST is host:port; psql wants them apart.
  local host="${MDL_DB_HOST:-127.0.0.1:5432}" port user="${MDL_DB_USER:-mendix}"
  port="${host##*:}"; host="${host%%:*}"
  case "$port" in ''|*[!0-9]*) port=5432 ;; esac
  # The name is interpolated into SQL: safe characters only.
  case "$MDL_DB_NAME" in
    ''|*[!A-Za-z0-9_]*)
      echo "   !! MDL_DB_NAME must be letters, digits or underscore; leaving the database alone" >&2
      return 1 ;;
  esac
  # PGPASSWORD is given per call, never exported to the tests and checkers.
  local pass="${MDL_DB_PASSWORD:-mendix}"
  if PGPASSWORD="$pass" "$psql" -w -h "$host" -p "$port" -U "$user" -d postgres -tAc \
       "SELECT 1 FROM pg_database WHERE datname='$MDL_DB_NAME'" 2>/dev/null | grep -q 1; then
    return 0
  fi
  echo "   creating database $MDL_DB_NAME"
  PGPASSWORD="$pass" "$psql" -w -h "$host" -p "$port" -U "$user" -d postgres \
    -c "CREATE DATABASE \"$MDL_DB_NAME\"" >/dev/null 2>&1
}

# --- 3. Model checks ---
# Each check runs in a background subshell, so it reports through files: check_<name> writes
# $WORK/<name>.summary and .detail and returns 0 pass / 1 problems / 2 could not run;
# run_cached adds .status and .secs; collect reads them after `wait`.
check_mx() {
  local out errors item
  # mx check runs on a copy: it rewrites the .mpr and would trigger --watch rebuilds.
  # The copy needs widgets/ and theme*/ as well; `cp -Rc` clones on APFS, else plain cp -R.
  local scratch="$WORK/mxcheck"
  mkdir -p "$scratch"
  for item in "$MPR" mprcontents widgets theme themesource javasource; do
    [ -e "$item" ] || continue
    cp -Rc "$item" "$scratch/" 2>/dev/null || cp -R "$item" "$scratch/" 2>/dev/null || {
      echo "mx check: could not run -- could not copy $item to a scratch directory" > "$WORK/mx.summary"; return 2; }
  done
  local -a mx_args=(docker check -p "$scratch/$MPR")
  [ -n "${MDL_MXBUILD_PATH:-}" ] && mx_args+=(--mxbuild-path "$MDL_MXBUILD_PATH")
  out="$("$MXCLI" "${mx_args[@]}" 2>&1)"
  # mx check exits 0 even with model errors, so read the count it prints.
  errors="$(printf '%s\n' "$out" | grep -oE 'contains: [0-9]+ errors' | grep -oE '[0-9]+' | tail -1)"
  if [ -z "$errors" ]; then
    printf '%s\n' "$out" | tail -3 > "$WORK/mx.detail"
    if [ -n "${MDL_MXBUILD_PATH:-}" ]; then
      echo "   (using $MDL_MXBUILD_PATH -- it must match this project's Mendix version)" \
        >> "$WORK/mx.detail"
    fi
    echo "mx check: could not run -- mx did not report an error count" > "$WORK/mx.summary"; return 2
  fi
  echo "mx check: $errors errors" > "$WORK/mx.summary"
  [ "$errors" = "0" ] && return 0
  printf '%s\n' "$out" | grep -E '^\[error\]|error' | head -10 > "$WORK/mx.detail"
  return 1
}

# Names from a `SHOW ... --json` listing on stdin; non-zero when it is not JSON.
qualified_names() {
  "$PY" -c 'import json,sys
rows = json.load(sys.stdin)
if not isinstance(rows, list):
    sys.exit(1)
for row in rows:
    name = row.get("Qualified Name") or row.get("QualifiedName")
    if name:
        print(name)' 2>/dev/null
}

# 0 passed, 1 findings, 2 broken. A traceback also exits 1, so 1 needs a FAIL line first.
checker_verdict() {
  case "$1" in
    0) return 0 ;;
    1) printf '%s\n' "$2" | head -1 | grep -qE '^FAIL ' && return 1 ;;
  esac
  return 2
}

# Describes every document of <kinds> into <dir>/<module>.mdl; failures go to
# $WORK/<label>.broken. False when anything failed.
describe_all() {
  local label="$1" dir="$2" kinds="$3" module kind listing names document
  local broken="$WORK/$label.broken"
  : > "$broken"
  mkdir -p "$dir"
  for module in $USER_MODULES; do
    for kind in $kinds; do
      if ! listing="$("$MXCLI" -p "$MPR" --json -c "SHOW $kind IN $module" 2>/dev/null)"; then
        echo "SHOW $kind IN $module failed" >> "$broken"; continue
      fi
      if ! names="$(printf '%s' "$listing" | qualified_names)"; then
        echo "SHOW $kind IN $module did not return a JSON list" >> "$broken"; continue
      fi
      while IFS= read -r document; do
        [ -n "$document" ] || continue
        "$MXCLI" describe "${kind%S}" "$document" -p "$MPR" >> "$dir/$module.mdl" 2>/dev/null \
          || echo "describe ${kind%S} $document failed" >> "$broken"
      done <<< "$names"
    done
  done
  [ ! -s "$broken" ]
}

# 0 when there are user modules; else writes the summary and returns 2 (unreadable)
# or 3 (none, which the caller turns into a pass).
modules_or_status() {
  if [ "${USER_MODULES_READ:-1}" != "1" ]; then
    echo "$1: could not run -- SHOW MODULES failed" > "$WORK/$1.summary"; return 2
  fi
  if [ -z "$USER_MODULES" ]; then
    echo "$1: no user module found" > "$WORK/$1.summary"; return 3
  fi
  return 0
}

# Only lint errors fail; warnings and info do not.
check_lint() {
  local out code line errors
  out="$("$MXCLI" lint -p "$MPR" 2>&1)"; code=$?
  # A .star file that fails to parse is skipped while lint still exits 0: not a pass.
  if printf '%s\n' "$out" | grep -qE 'rule file\(s\) skipped|rule file skipped'; then
    echo "lint: could not run -- $(printf '%s\n' "$out" | grep -cE '^Warning: rule file skipped') lint rule file(s) failed to load" > "$WORK/lint.summary"
    printf '%s\n' "$out" | grep -E '^Warning: rule file skipped' | sed 's/^Warning: rule file skipped: /  - /' | head -5 > "$WORK/lint.detail"
    return 2
  fi
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ issues:' | tail -1)"
  if [ -z "$line" ] && [ "$code" = "0" ] && printf '%s\n' "$out" | grep -qF 'No issues found.'; then
    echo "lint: No issues found." > "$WORK/lint.summary"
    return 0
  fi
  if [ -z "$line" ]; then
    echo "lint: could not run -- mxcli lint exited $code without a summary" > "$WORK/lint.summary"
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -5 > "$WORK/lint.detail"
    return 2
  fi
  echo "lint: $line" > "$WORK/lint.summary"
  errors="$(printf '%s\n' "$line" | grep -oE '[0-9]+ errors' | grep -oE '[0-9]+')"
  [ -n "$errors" ] && [ "$errors" != "0" ] || return 0
  printf '%s\n' "$out" | grep -E '✖|\[error\]' | head -10 > "$WORK/lint.detail"
  return 1
}

# Every page and ACT_ microflow must be named by a verify-*.test.sh `# covers:` line.
check_coverage() {
  [ -f tools/mdl-checks/check_test_coverage.py ] || {
    echo "coverage: could not run -- tools/mdl-checks/check_test_coverage.py is missing" > "$WORK/coverage.summary"
    return 2; }
  local gate out code
  modules_or_status coverage; gate=$?
  case "$gate" in
    0) ;;
    3) return 0 ;;   # no user modules: a real pass, summary already written
    *) return "$gate" ;;
  esac
  # All modules in one call: a test may cover a page in another module.
  # shellcheck disable=SC2086
  out="$("$PY" tools/mdl-checks/check_test_coverage.py . $USER_MODULES 2>&1)"; code=$?
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL|ERROR) ' | sed 's/^/coverage /' > "$WORK/coverage.summary"
  printf '%s\n' "$out" | grep -E '^[[:space:]]+- ' | head -10 > "$WORK/coverage.detail"
  case "$code" in
    0) return 0 ;;
    1) grep -q '^coverage FAIL ' "$WORK/coverage.summary" && return 1 ;;
  esac
  # The checker broke: keep its summary if it printed an ERROR line, else replace it.
  if ! grep -q '^coverage ERROR ' "$WORK/coverage.summary"; then
    echo "coverage: could not run -- check_test_coverage.py exited $code" > "$WORK/coverage.summary"
  fi
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -3 >> "$WORK/coverage.detail"
  return 2
}

# Runs check_mdl.py --skill naming over the described microflows and nanoflows.
check_naming() {
  [ -f tools/mdl-checks/check_mdl.py ] || {
    echo "naming: could not run -- tools/mdl-checks/check_mdl.py is missing" > "$WORK/naming.summary"
    return 2; }
  local gate out code
  modules_or_status naming; gate=$?
  case "$gate" in
    0) ;;
    3) return 0 ;;   # no user modules: a real pass, summary already written
    *) return "$gate" ;;
  esac
  if ! describe_all naming "$WORK/mdl" "MICROFLOWS NANOFLOWS"; then
    echo "naming: could not run -- $(head -1 "$WORK/naming.broken")" > "$WORK/naming.summary"
    head -5 "$WORK/naming.broken" | sed 's/^/  - /' > "$WORK/naming.detail"
    return 2
  fi
  if ! ls "$WORK"/mdl/*.mdl >/dev/null 2>&1; then
    echo "naming: no microflow or nanoflow to check" > "$WORK/naming.summary"; return 0
  fi
  out="$("$PY" tools/mdl-checks/check_mdl.py "$WORK/mdl" --skill naming 2>&1)"; code=$?
  checker_verdict "$code" "$out"; gate=$?
  if [ "$gate" = "2" ]; then
    echo "naming: could not run -- check_mdl.py exited $code" > "$WORK/naming.summary"
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -3 > "$WORK/naming.detail"
    return 2
  fi
  echo "naming: $(printf '%s\n' "$out" | head -1)" > "$WORK/naming.summary"
  printf '%s\n' "$out" | grep -E '^\s+- ' | head -10 > "$WORK/naming.detail"
  return "$gate"
}

# Widget spacing, read from `describe page` (Starlark lint rules cannot see widgets).
check_layout() {
  [ -f tools/mdl-checks/check_layout.py ] || {
    echo "layout: could not run -- tools/mdl-checks/check_layout.py is missing" > "$WORK/layout.summary"
    return 2; }
  local gate out code
  modules_or_status layout; gate=$?
  case "$gate" in
    0) ;;
    3) return 0 ;;   # no user modules: a real pass, summary already written
    *) return "$gate" ;;
  esac
  if ! describe_all layout "$WORK/pages" "PAGES"; then
    echo "layout: could not run -- $(head -1 "$WORK/layout.broken")" > "$WORK/layout.summary"
    head -5 "$WORK/layout.broken" | sed 's/^/  - /' > "$WORK/layout.detail"
    return 2
  fi
  if ! ls "$WORK"/pages/*.mdl >/dev/null 2>&1; then
    echo "layout: no page to check" > "$WORK/layout.summary"; return 0
  fi
  out="$("$PY" tools/mdl-checks/check_layout.py "$WORK/pages" 2>&1)"; code=$?
  checker_verdict "$code" "$out"; gate=$?
  if [ "$gate" = "2" ]; then
    echo "layout: could not run -- check_layout.py exited $code" > "$WORK/layout.summary"
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -3 > "$WORK/layout.detail"
    return 2
  fi
  echo "layout: $(printf '%s\n' "$out" | head -1)" > "$WORK/layout.summary"
  printf '%s\n' "$out" | grep -E '^\s+[-!] ' | head -12 > "$WORK/layout.detail"
  return "$gate"
}

# --- 4. Cache ---
# Only passes are cached, keyed on the bytes of every input the check reads plus the .mpr
# and mprcontents/; meta:<path> keys on size + mtime, env:NAME=value on the value.
fingerprint() {   # fingerprint <path>... -> one digest line; meta:<path> keys on size + mtime, env:NAME=value on the value
  "$PY" - "$MPR" mprcontents "$@" <<'PY_FP'
import hashlib, os, sys
h = hashlib.sha256()
def add(path, content):
    try:
        st = os.stat(path)
    except OSError:
        h.update(("missing %s\n" % path).encode()); return
    if os.path.isdir(path):
        for root, dirs, files in os.walk(path):
            dirs.sort()
            for name in sorted(files):
                add(os.path.join(root, name), content)
        return
    if not content:
        h.update(("%s %d %d\n" % (path, st.st_size, st.st_mtime_ns)).encode())
        return
    h.update(("%s %d\n" % (path, st.st_size)).encode())
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        h.update(("unreadable %s\n" % path).encode())
for arg in sys.argv[1:]:
    if arg.startswith("env:"):
        # env:NAME=value -- a setting read from the environment rather than a file.
        # The value is expanded by the caller, so it counts whether or not it was
        # exported.
        h.update(("%s\n" % arg).encode())
    elif arg.startswith("meta:"):
        add(arg[5:], False)
    else:
        add(arg, True)
print(h.hexdigest()[:24])
PY_FP
}
CACHE_DIR="$APP_DIR/.mxcli/gate-cache"
# The key includes a secret kept outside the project, so a forged cache entry cannot replay.
mdl_cache_secret() {
  local file="${MDL_CACHE_SECRET_FILE:-$HOME/.mxcli/gate-cache.secret}"
  if [ ! -s "$file" ]; then
    mkdir -p "$(dirname "$file")" 2>/dev/null || { echo none; return 0; }
    ( umask 077; "$PY" -c 'import secrets; print(secrets.token_hex(16))' > "$file" 2>/dev/null ) \
      || { echo none; return 0; }
  fi
  cat "$file" 2>/dev/null || echo none
}
# Replays a cached pass with "(cached HH:MM)", otherwise runs <function> and stores a pass.
run_cached() {
  local name="$1" fn="$2" key="" status; shift 2
  if [ "$USE_CACHE" = "1" ]; then
    key="$(fingerprint "$@" "env:MDL_CACHE_SECRET=$(mdl_cache_secret)" 2>/dev/null)"
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

# --- 5. Start checks ---
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  # Upgrading the gate, its config or mxcli must not replay an old pass.
  cache_inputs=(tests/gate.sh tests/harness.env "meta:$MXCLI")
  ( run_cached mx       check_mx       "${cache_inputs[@]}" "env:MDL_MXBUILD_PATH=${MDL_MXBUILD_PATH:-}" \
      meta:widgets meta:theme meta:themesource meta:javasource ) &
  ( run_cached lint     check_lint     "${cache_inputs[@]}" .claude/lint-rules ) &
  ( run_cached coverage check_coverage "${cache_inputs[@]}" tests tools/mdl-checks/check_test_coverage.py ) &
  ( run_cached naming   check_naming   "${cache_inputs[@]}" tools/mdl-checks/check_mdl.py ) &
  ( run_cached layout   check_layout   "${cache_inputs[@]}" tools/mdl-checks/check_layout.py ) &
  echo "== mx check, lint, coverage, naming and layout started (they need no app; running while the suite does)"
fi

# --- 6. --restart ---
# Kill the whole tree under `mxcli run`: TERM on mxcli alone orphans mxbuild and Java.
if [ "$RESTART" = "1" ]; then
  echo "== restarting this project's app"
  victims=""
  for pid in $(project_pids); do victims="$victims $(descendants "$pid") $pid"; done
  # SIGTERM, up to 15s for a clean stop, then SIGKILL.
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
  # Whatever answered belonged to the old runtime; do not adopt it.
  BASE_URL=""
fi

# Warn about drifted checkers before any verdict, and before the no-app exit below.
mdl_check_install_freshness

# --- 7. The app ---
if [ -z "${BASE_URL:-}" ]; then
  for candidate in "http://localhost:$APP_PORT" http://localhost:8080; do
    answers "$candidate" && { BASE_URL="$candidate"; break; }
  done
fi
if [ -z "${BASE_URL:-}" ] || ! answers "$BASE_URL"; then
  if [ "$BOOT" = "1" ]; then
    # An orphaned `mxbuild --serve` holds port 6543 and makes the boot fail.
    if command -v pgrep >/dev/null 2>&1 && pgrep -f 'mxbuild' >/dev/null 2>&1; then
      echo "   !! an mxbuild process is already running. If this boot fails on"
      echo "      'port 6543 (mxbuild serve) is already in use', it is an orphan:"
      echo "      pgrep -af 'mxbuild|runtimelauncher'   then kill that pid"
    fi
    # MDL_BOOT_COMMAND replaces `mxcli run --local` where that cannot boot (Windows).
    if [ -n "${MDL_BOOT_COMMAND:-}" ]; then
      echo "== no app answering; booting with MDL_BOOT_COMMAND"
      ensure_database || true
      echo "   running: $MDL_BOOT_COMMAND"
      # `( cmd & )` detaches the app: `wait` does not block on it and it outlives the gate.
      ( bash -c "$MDL_BOOT_COMMAND" > .mxcli/gate-boot.log 2>&1 & )
      BASE_URL="http://localhost:$APP_PORT"
      wait_for_boot .mxcli/gate-boot.log
      booted_by_command=1
    fi
    # Default boot: `mxcli run --local --watch` (hot reload).
    if [ -z "$booted_by_command" ]; then
      echo "== no app answering; booting $MPR on port $APP_PORT with hot reload"
      boot_args=(run --local -p "$MPR" --app-port "$APP_PORT" --watch)
      # A second app on this machine needs its own admin and mxbuild ports.
      [ -n "${ADMIN_PORT:-}" ] && boot_args+=(--admin-port "$ADMIN_PORT")
      [ -n "${SERVE_PORT:-}" ] && boot_args+=(--serve-port "$SERVE_PORT")
      if [ -n "${MDL_DB_NAME:-}" ]; then
        ensure_database || true
        boot_args+=(--db-name "$MDL_DB_NAME")
        [ -n "${MDL_DB_HOST:-}" ] && boot_args+=(--db-host "$MDL_DB_HOST")
        [ -n "${MDL_DB_USER:-}" ] && boot_args+=(--db-user "$MDL_DB_USER")
        [ -n "${MDL_DB_PASSWORD:-}" ] && boot_args+=(--db-password "$MDL_DB_PASSWORD")
      else
        # A fresh project has no database; --ensure-db creates it only when missing.
        boot_args+=(--ensure-db)
      fi
      ( "$MXCLI" "${boot_args[@]}" > .mxcli/gate-boot.log 2>&1 & )
      BASE_URL="http://localhost:$APP_PORT"
      wait_for_boot .mxcli/gate-boot.log
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

# --- 8. Preflights ---
# Warnings before the tests; only preflight_session stops the gate (exit 2), on a
# trial-licence session refusal in the runtime log within the last two minutes.
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

# Warns when the runtime serves an older model: security and entity changes do not hot-apply.
preflight_stale_model() {
  local started

  # Nothing is stale when the --watch boot log's last line says the change was reloaded.
  local boot_log="$APP_DIR/.mxcli/gate-boot.log"
  if [ -f "$boot_log" ] && [ ! "$MPR" -nt "$boot_log" ] \
     && tail -1 "$boot_log" 2>/dev/null | grep -q 'applied via reload'; then
    return 0
  fi

  # Primary signal, needs no pgrep (Git Bash): .mpr newer than the built deployment.
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

  # Secondary signal: .mpr newer than this project's oldest runtime process.
  command -v pgrep >/dev/null 2>&1 || return 0
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

# Warns about a missing browser binary, a broken local database, and missing credentials.
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

  mdl_check_local_database

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

# --- 9. Tests ---
# failures -> exit 1, cannot_run -> exit 2, summary -> the verdict lines.
failures=()
cannot_run=()
summary=()

# Records each script's first red run in .mxcli/red-first/. Under --only, a script that goes
# green without one is flagged once: a test that never failed may assert nothing.
record_red_first() {   # record_red_first <runner output> <environment cause or "">
  [ -n "$ONLY" ] || [ "$TESTS_ONLY" = "1" ] || return 0
  [ -z "${2:-}" ] || return 0
  local out="$1" dir="$APP_DIR/.mxcli/red-first" line name verdict
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$out" | grep -E '^\s+(PASS|FAIL)\s' | while read -r verdict name _; do
    name="${name%.test.sh}"
    case "$name" in ''|*/*|.*) continue ;; esac
    case "$verdict" in
      FAIL) [ -f "$dir/$name" ] || date '+%Y-%m-%d %H:%M' > "$dir/$name" ;;
      PASS)
        [ -n "$ONLY" ] || continue
        if [ ! -f "$dir/$name" ] && [ ! -f "$dir/$name.green" ]; then
          date '+%Y-%m-%d %H:%M' > "$dir/$name.green"
          # Also to a file: this runs in a `while read` subshell and must reach the summary.
          echo "$name: went green without ever being red -- break the feature once and watch it go red" \
            >> "$WORK/redfirst.note"
          echo "   !! $name went green without ever being red here. A test that has never"
          echo "      failed may assert nothing: break the feature once (an mxcli exec that"
          echo "      changes the message, say) and watch this same command go red, then undo it."
        fi ;;
    esac
  done
}

# Runs the suite (or the --only matches) in this shell, appending to the arrays directly.
step_tests() {
  local targets=("tests/") script
  if [ -n "$ONLY" ]; then
    targets=()
    for script in tests/verify-*"$ONLY"*.test.sh; do
      [ -f "$script" ] && targets+=("$script")
    done
    [ ${#targets[@]} -gt 0 ] || { echo "no test matches '$ONLY'" >&2; exit 2; }
  fi
  echo "== tests: ${targets[*]}"
  local out status line
  export PY MXCLI BASE_URL SCRIPT_TIMEOUT
  MODULE="${MODULE:-$(printf '%s\n' "$USER_MODULES" | head -1)}"
  [ -n "$MODULE" ] || MODULE="$(user_modules | head -1)"
  export MODULE
  # One licence session: a full run reuses it; --only keeps it signed in between runs.
  if [ -n "$ONLY" ]; then
    export KEEP_SESSION="${KEEP_SESSION:-1}"
  else
    export MDL_SESSION_REUSE="${MDL_SESSION_REUSE:-1}"
  fi
  local started=$SECONDS
  out="$("$MXCLI" playwright verify "${targets[@]}" -p "$MPR" \
        --base-url "$BASE_URL" --timeout "$SCRIPT_TIMEOUT" --keep-open 2>&1)"
  status=$?
  echo $((SECONDS - started)) > "$WORK/tests.secs"
  printf '%s\n' "$out" | grep -E '^\s+(PASS|FAIL)|^\s+FAIL:|^Total:'
  # One sign-out for a full run; lib.sh is sourced in a subshell to keep it out of the gate.
  if [ -z "$ONLY" ] && [ "${KEEP_SESSION:-0}" != "1" ]; then
    ( . tests/lib.sh >/dev/null 2>&1; release_session ) 2>/dev/null
  fi

  # Name an environment cause: a dead app or closed browser looks like broken features.
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
  record_red_first "$out" "$environment"

  line="$(printf '%s\n' "$out" | grep -E '^Total:' | tail -1)"
  if [ -n "$line" ]; then
    if [ -n "$environment" ]; then
      summary+=("tests: $line -- ENVIRONMENT, not the feature: $environment")
    else
      summary+=("tests: $line")
    fi
  else
    # No Total line: the runner never ran the scripts; show the line that says why.
    local why
    why="$(printf '%s\n' "$out" | grep -iE '^error|error:|panic|unknown flag|no such file' | tail -1)"
    [ -n "$why" ] || why="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
    echo "   the runner produced no results: $why"
    summary+=("tests: no result -- ${environment:-${why:-the runner printed nothing}}")
  fi
  if [ "$status" != "0" ]; then
    failures+=("tests")
    if [ -z "$environment" ] && [ -x tests/diagnose.sh ]; then
      echo "== facts (tests/diagnose.sh)"
      bash tests/diagnose.sh 2>&1 | sed 's/^/   /' | head -40
    fi
  fi
}

# --- 10. Run ---
# Reads one background check's files into summary, failures or cannot_run.
collect() {
  local name="$1" label="$2" status line
  if [ ! -f "$WORK/$name.status" ]; then
    # No status file: the worker died. Not a pass.
    summary+=("$label: could not run -- the check left no result")
    cannot_run+=("$label")
    return 0
  fi
  status="$(cat "$WORK/$name.status")"
  if [ -s "$WORK/$name.summary" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && summary+=("$line")
    done < "$WORK/$name.summary"
  fi
  case "$status" in
    0) ;;
    2) echo "== $label (could not run)"
       [ -s "$WORK/$name.detail" ] && cat "$WORK/$name.detail"
       cannot_run+=("$label") ;;
    *) [ -s "$WORK/$name.detail" ] && { echo "== $label"; cat "$WORK/$name.detail"; }
       failures+=("$label") ;;
  esac
}

preflight_session
preflight_environment
preflight_stale_model
step_tests
if [ -s "$WORK/redfirst.note" ]; then
  while IFS= read -r line; do summary+=("$line"); done < "$WORK/redfirst.note"
fi
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  wait
  collect mx "mx check"
  collect lint "lint"
  collect coverage "coverage"
  collect naming "naming"
  collect layout "layout"
fi

# --- 11. Summary ---
# Any failure exits 1; could-not-run alone exits 2; otherwise DONE, exit 0.
echo
echo "== gate"
for line in "${summary[@]}"; do echo "   $line"; done
timing=""
for name in tests mx lint coverage naming layout; do
  [ -f "$WORK/$name.secs" ] && timing="$timing $name $(cat "$WORK/$name.secs")s,"
done
echo "   timing:${timing} wall $((SECONDS - GATE_START))s"
if [ ${#failures[@]} -gt 0 ]; then
  echo "   NOT DONE — failed: ${failures[*]}"
  [ ${#cannot_run[@]} -eq 0 ] || echo "   and could not run: ${cannot_run[*]}"
  exit 1
fi
if [ ${#cannot_run[@]} -gt 0 ]; then
  echo "   NOT DONE — could not run: ${cannot_run[*]}"
  echo "   A check that did not run has not passed. Fix what stopped it, then run the gate again."
  exit 2
fi
echo "   DONE — every check passed"
