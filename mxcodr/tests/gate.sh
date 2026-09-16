#!/usr/bin/env bash
# The done gate: everything "finished" means, in one command.
#
#   bash tests/gate.sh                    # suite + mx check + lint + coverage + naming + layout
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
# The name ends up in a pgrep pattern whose matches are killed, and in mxcli's
# arguments. A committed `0|.*|.mpr` turned that pattern into one matching every
# process this user owns, and --restart would have killed all of them; a committed
# `0-clean.mpr` sorts first and would have become the model every check ran against.
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

# A boot that cannot succeed, recognised from its own log. Without this the wait
# loop below polls a port nothing will ever answer on until BOOT_TIMEOUT -- three
# minutes, measured, for a model that fails `mxbuild` with CE1613 while the log
# said so in the first two seconds. The reason is what the session needs, and it
# needs it now, not at the timeout.
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
GATE_START=$SECONDS

# This project's own modules -- read once, used by coverage, naming and the cache.
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
# USER_MODULES_READ says whether the list could be read at all. An empty list from a
# model with no module of its own is a real answer; an empty list because SHOW
# MODULES failed is not, and every model check below tells the two apart.
USER_MODULES=""; USER_MODULES_READ=1
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  USER_MODULES="$(user_modules)" || USER_MODULES_READ=0
fi

# --- the processes that are this project's app ---------------------------------
# Matched on the project, not on the program name: another app's runtime on the
# same machine (a second agent, a second checkout) is not this one's, and its
# start time says nothing about this model. Oldest first.
project_pids() {
  command -v pgrep >/dev/null 2>&1 || return 0
  { pgrep -f "runtimelauncher.*$APP_DIR" 2>/dev/null
    pgrep -f "mxcli(\.exe)? run .*$(mdl_ere_quote "$MPR")" 2>/dev/null; } | sort -un
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
  # The database name is interpolated into SQL, and psql -c accepts several
  # statements, so a name carrying a quote could run DDL of its own choosing.
  case "$MDL_DB_NAME" in
    ''|*[!A-Za-z0-9_]*)
      echo "   !! MDL_DB_NAME must be letters, digits or underscore; leaving the database alone" >&2
      return 1 ;;
  esac
  # Given per call, never exported: an exported PGPASSWORD is inherited by every
  # verify-*.test.sh and every checker the gate starts.
  local pass="${MDL_DB_PASSWORD:-mendix}"
  if PGPASSWORD="$pass" "$psql" -w -h "$host" -p "$port" -U "$user" -d postgres -tAc \
       "SELECT 1 FROM pg_database WHERE datname='$MDL_DB_NAME'" 2>/dev/null | grep -q 1; then
    return 0
  fi
  echo "   creating database $MDL_DB_NAME"
  PGPASSWORD="$pass" "$psql" -w -h "$host" -p "$port" -U "$user" -d postgres \
    -c "CREATE DATABASE \"$MDL_DB_NAME\"" >/dev/null 2>&1
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
      echo "mx check: could not run -- could not copy $item to a scratch directory" > "$WORK/mx.summary"; return 2; }
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
    echo "mx check: could not run -- mx did not report an error count" > "$WORK/mx.summary"; return 2
  fi
  echo "mx check: $errors errors" > "$WORK/mx.summary"
  [ "$errors" = "0" ] && return 0
  printf '%s\n' "$out" | grep -E '^\[error\]|error' | head -10 > "$WORK/mx.detail"
  return 1
}

# --- the model checks ------------------------------------------------------------
# Every check returns 0 (passed), 1 (found problems) or 2 (could not run). The third
# is not a kind of pass. Until 2026.09.13 a lint that crashed, a model that could not
# be described, or a worker that died all fell through to "return 0", and the gate
# printed DONE over checks that had never looked at anything.

# qualified_names: the names out of a `SHOW ... --json` listing on stdin. Exits
# non-zero when the listing is not JSON, which is how a failed query shows up.
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

# checker_verdict <exit> <output>: 0 passed, 1 findings, 2 the checker itself broke.
# A Python traceback also exits 1, so a 1 only counts as findings when the checker
# printed its FAIL verdict line first.
checker_verdict() {
  case "$1" in
    0) return 0 ;;
    1) printf '%s\n' "$2" | head -1 | grep -qE '^FAIL ' && return 1 ;;
  esac
  return 2
}

# describe_all <label> <dir> <kinds> <describe-type-from-kind>: describe every document
# of those kinds in every user module into <dir>/<module>.mdl. Any failed listing or
# describe is written to $WORK/<label>.broken -- not swallowed -- and the loop reads
# from a here-string, not a pipe, so it runs in this shell and nothing is lost.
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

# modules_or_status <label>: prints nothing and returns 0 when there are modules to
# check; otherwise writes the summary and returns the status the check should end on.
modules_or_status() {
  if [ "${USER_MODULES_READ:-1}" != "1" ]; then
    echo "$1: could not run -- SHOW MODULES failed" > "$WORK/$1.summary"; return 2
  fi
  if [ -z "$USER_MODULES" ]; then
    echo "$1: no user module found" > "$WORK/$1.summary"; return 3
  fi
  return 0
}

check_lint() {
  local out code line errors
  out="$("$MXCLI" lint -p "$MPR" 2>&1)"; code=$?
  # A .star file that does not parse is skipped with a warning on stderr, and lint
  # still exits 0 with a normal-looking summary -- measured on 2026-09-13 with a rule
  # that had a syntax error. Its rules never ran, so this is not a pass.
  if printf '%s\n' "$out" | grep -qE 'rule file\(s\) skipped|rule file skipped'; then
    echo "lint: could not run -- $(printf '%s\n' "$out" | grep -cE '^Warning: rule file skipped') lint rule file(s) failed to load" > "$WORK/lint.summary"
    printf '%s\n' "$out" | grep -E '^Warning: rule file skipped' | sed 's/^Warning: rule file skipped: /  - /' | head -5 > "$WORK/lint.detail"
    return 2
  fi
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ issues:' | tail -1)"
  # A clean project prints no count at all, only this sentence.
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
  # Warnings and info are for a human to weigh; only errors gate.
  [ -n "$errors" ] && [ "$errors" != "0" ] || return 0
  printf '%s\n' "$out" | grep -E '✖|\[error\]' | head -10 > "$WORK/lint.detail"
  return 1
}

check_coverage() {
  [ -f tools/mdl-checks/check_test_coverage.py ] || {
    echo "coverage: could not run -- tools/mdl-checks/check_test_coverage.py is missing" > "$WORK/coverage.summary"
    return 2; }
  local gate out code
  modules_or_status coverage; gate=$?
  [ "$gate" = "0" ] || { [ "$gate" = "3" ] && return 0; return "$gate"; }
  # All modules in one call: a test may cover a page in another module, and only a
  # checker that sees the whole project can tell that claim from a stale one.
  # shellcheck disable=SC2086
  out="$("$PY" tools/mdl-checks/check_test_coverage.py . $USER_MODULES 2>&1)"; code=$?
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL|ERROR) ' | sed 's/^/coverage /' > "$WORK/coverage.summary"
  printf '%s\n' "$out" | grep -E '^[[:space:]]+- ' | head -10 > "$WORK/coverage.detail"
  case "$code" in
    0) return 0 ;;
    1) grep -q '^coverage FAIL ' "$WORK/coverage.summary" && return 1 ;;
  esac
  [ -s "$WORK/coverage.summary" ] && ! grep -q '^coverage ERROR ' "$WORK/coverage.summary" \
    && : > "$WORK/coverage.summary"
  [ -s "$WORK/coverage.summary" ] \
    || echo "coverage: could not run -- check_test_coverage.py exited $code" > "$WORK/coverage.summary"
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -3 >> "$WORK/coverage.detail"
  return 2
}

# The naming rules -- captions on decisions and on every action, real variable
# names, no stacked positions -- live in check_mdl.py, which reads MDL text rather
# than the model catalog. Nothing ran it before, so those rules were documentation
# an agent could skip without the gate noticing. `describe module` is ground truth:
# it is what actually landed in the .mpr, not what a script file claimed.
check_naming() {
  [ -f tools/mdl-checks/check_mdl.py ] || {
    echo "naming: could not run -- tools/mdl-checks/check_mdl.py is missing" > "$WORK/naming.summary"
    return 2; }
  local gate out code
  modules_or_status naming; gate=$?
  [ "$gate" = "0" ] || { [ "$gate" = "3" ] && return 0; return "$gate"; }
  # `describe module` emits the module and its roles only -- the documents have to be
  # enumerated and described one by one. Thirteen microflows cost well under a second.
  if ! describe_all naming "$WORK/mdl" "MICROFLOWS NANOFLOWS"; then
    echo "naming: could not run -- $(head -1 "$WORK/naming.broken")" > "$WORK/naming.summary"
    head -5 "$WORK/naming.broken" | sed 's/^/  - /' > "$WORK/naming.detail"
    return 2
  fi
  # A module with no microflow at all is a real, empty answer.
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

# --- caching the model checks --------------------------------------------------
# A check's key is a digest of every input it reads. The model, the tests, the
# checkers, gate.sh and harness.env are keyed on their bytes: a same-size edit with
# its timestamp restored must not replay an old green, and hashing all of it costs
# about 10ms on InvoiceDesk. The mxcli binary (90MB) and the widget and theme trees
# are keyed on size + mtime (meta:), where replacing a file always moves the
# timestamp. Only a passing result is stored, so a cached line is always a line
# that was green when it ran; a red check, and one that could not run, runs again
# every time.
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
# A cached summary is printed as a pass, and the cache lives in the project, so a
# forged <check>.key/<check>.summary pair used to be enough to make any red check
# report green. The key now also depends on a secret kept outside the project, so a
# pair can only be produced by something that has already read this machine's files.
mdl_cache_secret() {
  local file="${MDL_CACHE_SECRET_FILE:-$HOME/.mxcli/gate-cache.secret}"
  if [ ! -s "$file" ]; then
    mkdir -p "$(dirname "$file")" 2>/dev/null || { echo none; return 0; }
    ( umask 077; "$PY" -c 'import secrets; print(secrets.token_hex(16))' > "$file" 2>/dev/null ) \
      || { echo none; return 0; }
  fi
  cat "$file" 2>/dev/null || echo none
}
# run_cached <name> <function> <extra input paths...>
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

# Spacing is the one defect every other verdict lets through: a page can pass tests,
# mx check, lint, coverage and naming and still render a label welded to two buttons,
# because nothing in the model is wrong -- the widgets simply carry no margin. Read
# from `describe page`, which prints DesignProperties; mxcli's Starlark rules cannot
# see widgets at all (a page object there exposes only widget_count).
check_layout() {
  [ -f tools/mdl-checks/check_layout.py ] || {
    echo "layout: could not run -- tools/mdl-checks/check_layout.py is missing" > "$WORK/layout.summary"
    return 2; }
  local gate out code
  modules_or_status layout; gate=$?
  [ "$gate" = "0" ] || { [ "$gate" = "3" ] && return 0; return "$gate"; }
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
  # Errors gate; the heading warning is printed but does not, the same way lint's
  # warnings do not.
  printf '%s\n' "$out" | grep -E '^\s+[-!] ' | head -12 > "$WORK/layout.detail"
  return "$gate"
}

# --- start the slow, independent work first ---------------------------------
if [ "$TESTS_ONLY" = "0" ] && [ -z "$ONLY" ]; then
  # Every result also depends on the gate that produced it, its configuration and
  # the mxcli that read the model: upgrading any of them must not replay old greens.
  cache_inputs=(tests/gate.sh tests/harness.env "meta:$MXCLI")
  # MDL_MXBUILD_PATH picks which `mx` checks the model. Set in harness.env it is
  # already in the key; set only in the shell it is not, so its value goes in too.
  ( run_cached mx       check_mx       "${cache_inputs[@]}" "env:MDL_MXBUILD_PATH=${MDL_MXBUILD_PATH:-}" \
      meta:widgets meta:theme meta:themesource meta:javasource ) &
  ( run_cached lint     check_lint     "${cache_inputs[@]}" .claude/lint-rules ) &
  ( run_cached coverage check_coverage "${cache_inputs[@]}" tests tools/mdl-checks/check_test_coverage.py ) &
  ( run_cached naming   check_naming   "${cache_inputs[@]}" tools/mdl-checks/check_mdl.py ) &
  ( run_cached layout   check_layout   "${cache_inputs[@]}" tools/mdl-checks/check_layout.py ) &
  echo "== mx check, lint, coverage, naming and layout started (they need no app; running while the suite does)"
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

# Checkers older than the bundle, or edited since they were installed. A gate that
# passes because its checkers are out of date still prints the green, so this is
# said before any verdict is -- and before the missing-app bail below, which would
# otherwise swallow it.
mdl_check_install_freshness

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
      echo "   running: $MDL_BOOT_COMMAND"
      ( bash -c "$MDL_BOOT_COMMAND" > .mxcli/gate-boot.log 2>&1 & )
      BASE_URL="http://localhost:$APP_PORT"
      waited=0
      until answers "$BASE_URL"; do
        sleep 1
        waited=$((waited + 1))
        boot_failed .mxcli/gate-boot.log && report_boot_failure .mxcli/gate-boot.log "$waited"
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
    else
      # `mxcli new` creates no database, and `run --local` refuses to create one
      # unasked: a fresh project's first boot died in 13s with "The database to be
      # used does not exist", before any test ran. --ensure-db creates it when it is
      # missing and does nothing when it is there, so it costs a check per boot.
      boot_args+=(--ensure-db)
    fi
    ( "$MXCLI" "${boot_args[@]}" > .mxcli/gate-boot.log 2>&1 & )
    BASE_URL="http://localhost:$APP_PORT"
    waited=0
    until answers "$BASE_URL"; do
      perl -e 'select undef, undef, undef, 1' 2>/dev/null || sleep 1
      waited=$((waited + 1))
      boot_failed .mxcli/gate-boot.log && report_boot_failure .mxcli/gate-boot.log "$waited"
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

  # A local database a deploy build left half-written, or a lock a killed runtime
  # left behind. Both stop a boot with a message about neither.
  mdl_check_local_database

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
cannot_run=()
summary=()

# A test that has never failed may assert nothing at all, and nothing about its
# text says which. So the gate keeps the record: the first red run of a script,
# under --only, leaves .mxcli/red-first/<script>. A script that goes green under
# --only with no such record is named once -- and only then is it worth breaking
# the feature on purpose to see the test notice. Breaking every feature for every
# test, as one session did, cost 15 minutes and proved what the red-first run had
# already proved.
record_red_first() {   # record_red_first <runner output> <environment cause or "">
  # Under --only, and under --tests-only -- one session ran the whole suite red on
  # purpose, before any model existed, exactly to have that on record.
  [ -n "$ONLY" ] || [ "$TESTS_ONLY" = "1" ] || return 0
  # A failure the app or the browser caused proves nothing about the test.
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
          # Written to a file, not just echoed: this runs inside a `while read`
          # subshell, and the line matters enough to survive into the summary
          # block -- a session whose own `grep -E "FAIL:|PASS|Total:"` dropped it
          # went looking for the markers by hand instead.
          echo "$name: went green without ever being red -- break the feature once and watch it go red" \
            >> "$WORK/redfirst.note"
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
  # The module oql_count and oql_value query, so a test need not spell it out and
  # lib.sh need not look it up per script.
  MODULE="${MODULE:-$(printf '%s\n' "$USER_MODULES" | head -1)}"
  [ -n "$MODULE" ] || MODULE="$(user_modules | head -1)"
  export MODULE
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
  record_red_first "$out" "$environment"

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
  local name="$1" label="$2" status
  if [ ! -f "$WORK/$name.status" ]; then
    # A worker that left no status died before it finished -- killed, out of
    # memory, a syntax error. None of that is a pass.
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
