# tests/gate/tests.sh -- running tests/verify-*.test.sh and recording their result.
# Sourced by tests/gate.sh; defines functions only. Entry point: step_tests.
# Results go to the arrays the gate prints: failures (exit 1), cannot_run (exit 2), summary.

# Records each script's first red run in .mxcli/red-first/. Under --only, a script that goes
# green without one is flagged once: a test that never failed may assert nothing.
# Nothing is recorded while the runtime serves an older model: that red is not the test's.
record_red_first() {   # record_red_first <runner output> <environment cause or "">
  [ -n "$ONLY" ] || [ "$TESTS_ONLY" = "1" ] || return 0
  [ -z "${2:-}" ] || return 0
  if [ -s "$WORK/stale.note" ]; then
    echo "   !! red run not recorded: the app serves an older model. Restart, then watch the test go red"
    return 0
  fi
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

# A MODULE set by the caller goes to every test. Otherwise each test takes the module on its own
# `# covers:` line (lib.sh), and only a test without one falls back to MDL_DEFAULT_MODULE.
export_test_module() {
  if [ -n "${MODULE:-}" ]; then
    export MODULE
    return 0
  fi
  MDL_DEFAULT_MODULE="$(printf '%s\n' "$USER_MODULES" | head -1)"
  [ -n "$MDL_DEFAULT_MODULE" ] || MDL_DEFAULT_MODULE="$(mdl_user_modules "$MPR" | head -1)"
  export MDL_DEFAULT_MODULE
}

# Runs the suite (or the --only matches) in this shell, appending to the arrays directly.
step_tests() {
  local -a targets
  local out status environment started=$SECONDS
  select_test_targets
  echo "== tests: ${targets[*]}"
  out="$(run_suite "${targets[@]}")"
  status=$?
  echo $((SECONDS - started)) > "$WORK/tests.secs"
  printf '%s\n' "$out" | grep -E '^\s+(PASS|FAIL)|^\s+FAIL:|^Total:'
  # One sign-out for a full run; lib.sh is sourced in a subshell to keep it out of the gate.
  if [ -z "$ONLY" ] && [ "${KEEP_SESSION:-0}" != "1" ]; then
    ( . tests/lib.sh >/dev/null 2>&1; release_session ) 2>/dev/null
  fi
  environment="$(environment_cause "$out")"
  if [ -n "$environment" ]; then
    echo "   !! not a feature failure: $environment"
  fi
  record_red_first "$out" "$environment"
  record_suite_result "$out" "$status" "$environment"
}

# Sets targets: tests/ for the whole suite, or the scripts --only names (exit 2 when none match).
select_test_targets() {
  local script
  targets=("tests/")
  [ -n "$ONLY" ] || return 0
  targets=()
  for script in tests/verify-*"$ONLY"*.test.sh; do
    [ -f "$script" ] && targets+=("$script")
  done
  [ ${#targets[@]} -gt 0 ] || { echo "no test matches '$ONLY'" >&2; exit 2; }
}

# run_suite <target>... -- the runner's output; its exit code is the suite's.
run_suite() {
  export PY MXCLI BASE_URL SCRIPT_TIMEOUT
  export_test_module
  # One licence session: a full run reuses it; --only keeps it signed in between runs.
  if [ -n "$ONLY" ]; then
    export KEEP_SESSION="${KEEP_SESSION:-1}"
  else
    export MDL_SESSION_REUSE="${MDL_SESSION_REUSE:-1}"
  fi
  "$MXCLI" playwright verify "$@" -p "$MPR" \
    --base-url "$BASE_URL" --timeout "$SCRIPT_TIMEOUT" --keep-open 2>&1
}

# environment_cause <runner output> -- a dead app or a closed browser looks like broken
# features; prints what happened, or nothing.
environment_cause() {
  case "$1" in
    *ERR_CONNECTION_REFUSED*|*ECONNREFUSED*)
      echo "the app stopped answering on $BASE_URL during the run (a model change that cannot hot-apply stops the runtime; restart it, or use --boot-if-needed)" ;;
    *"browser has been closed"*|*"Target page, context or browser has been closed"*)
      echo "the browser was closed while the suite was running (playwright-cli has one shared browser -- another session or command closed it)" ;;
    *"opening browser: exit status"*)
      echo "the browser could not be started (check .playwright/cli.config.json executablePath, then: playwright-cli close && playwright-cli open)" ;;
  esac
}

# record_suite_result <runner output> <exit code> <environment cause> -- the tests line of the
# summary, a tests failure, and the facts from diagnose.sh when a feature failed.
record_suite_result() {
  local out="$1" status="$2" environment="$3" line why
  line="$(printf '%s\n' "$out" | grep -E '^Total:' | tail -1)"
  if [ -n "$line" ] && [ -n "$environment" ]; then
    summary+=("tests: $line -- ENVIRONMENT, not the feature: $environment")
  elif [ -n "$line" ]; then
    summary+=("tests: $line")
  else
    # No Total line: the runner never ran the scripts; show the line that says why.
    why="$(printf '%s\n' "$out" | grep -iE '^error|error:|panic|unknown flag|no such file' | tail -1)"
    [ -n "$why" ] || why="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
    echo "   the runner produced no results: $why"
    summary+=("tests: no result -- ${environment:-${why:-the runner printed nothing}}")
  fi
  [ "$status" != "0" ] || return 0
  failures+=("tests")
  if [ -z "$environment" ] && [ -x tests/diagnose.sh ]; then
    echo "== facts (tests/diagnose.sh)"
    bash tests/diagnose.sh 2>&1 | sed 's/^/   /' | head -40
  fi
}
