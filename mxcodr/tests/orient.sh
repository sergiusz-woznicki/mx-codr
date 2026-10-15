#!/usr/bin/env bash
# orient.sh -- app facts at session start: app state, security, tests and coverage, the rulebook,
# navigation, module structure. Run by the agent (or you) once per session.
#   bash tests/orient.sh        (env: APP_PORT, default 8081; MPR when there are several)
# Lookups run in parallel into numbered files. Exit 2 without a .mpr, else 0.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
cd "$APP_DIR"
. "$HARNESS_DIR/portable.sh"
mdl_find_mpr || exit 2
APP_PORT="${APP_PORT:-8081}"
# MDL_DB_RESET=session: the session's database snapshot, before anything it does writes data.
[ -f "$HARNESS_DIR/db-snapshot.sh" ] && bash "$HARNESS_DIR/db-snapshot.sh" take
WORK="$(mdl_tmpdir mdl-orient)"
trap 'rm -rf "$WORK"' EXIT


# --- Sections: each prints its own "== heading" and runs in the background. ---

structure_section() {
  echo "== structure (this app's own modules; System and Atlas are not listed)"
  for module in $(mdl_user_modules "$MPR"); do
    "$MXCLI" -p "$MPR" -c "SHOW STRUCTURE DEPTH 2 IN $module" 2>&1 | head -60
  done
}

security_section() {
  echo "== security"
  "$MXCLI" -p "$MPR" -c "SHOW PROJECT SECURITY" 2>&1 | grep -iE 'security level|demo users|guest|user roles'
  "$MXCLI" -p "$MPR" -c "SHOW USER ROLES" 2>&1 | grep -E '^\|' | head -10
  # Whether a Marketplace module can be installed: known before a feature needs one.
  [ -f tests/marketplace-login.sh ] && bash tests/marketplace-login.sh status | sed 's/^/   /'
}

navigation_section() {
  echo "== navigation"
  "$MXCLI" -p "$MPR" -c "SHOW NAVIGATION HOMES" 2>&1 | head -10
  "$MXCLI" -p "$MPR" -c "SHOW NAVIGATION MENU" 2>&1 | head -15
}

tests_section() {
  local script module
  echo "== tests already here (and what each one covers)"
  for script in tests/verify-*.test.sh; do
    [ -f "$script" ] || continue
    printf '   %-42s %s\n' "$(basename "$script")" \
      "$(grep -m1 '^# covers:' "$script" | sed 's/^# covers: //')"
  done
  echo "== coverage"
  if [ -f tools/mdl-checks/check_test_coverage.cjs ]; then
    # One call for all modules, as the gate and the after-exec hook do: asked one module at a
    # time, a test that covers another module's page is reported as naming something stale.
    # shellcheck disable=SC2046
    "$NODE" tools/mdl-checks/check_test_coverage.cjs . $(mdl_user_modules "$MPR") 2>&1 \
      | grep -E '^(PASS|FAIL|ERROR)' | sed 's/^/   /'
  fi
}

# The rulebook: how many rules, and what the person changed (a level, an exception). mxcli lint
# itself is no longer run here: its advice is read on request (LINT01 in tests/rulebook/).
rulebook_section() {
  [ -d tests/rulebook ] || return 0
  echo "== rulebook (tests/rulebook/<group>/<CODE>.md; bash tests/rules.sh)"
  local count changed
  count="$(mdl_rulebook list 2>/dev/null | grep -c .)"
  if changed="$(mdl_rulebook changes 2>/dev/null)"; then
    echo "   $count rules; changed by the person: ${changed:-none}"
  else
    echo "   $count cards -- $(mdl_rulebook check 2>&1 | tail -1)"
  fi
}

# How the agent learns whether to ask the person before building (skill requirements-interview):
# MDL_REQUIREMENTS in tests/harness.env -- ask (default), assume (nobody answers), off.
requirements_line() {
  local slices
  slices="$(ls docs/brain/plan/*.md 2>/dev/null | wc -l | tr -d ' ')"
  case "${MDL_REQUIREMENTS:-ask}" in
    off) echo "   requirements: off -- no interview before building" ;;
    assume) echo "   requirements: assume -- nobody answers: before the first feature, take your recommended answers as assumptions (skill requirements-interview) and build on; never end a turn on a plan or a question, only at DONE or at a step only the person can take; $slices slice(s) in docs/brain/plan" ;;
    *) echo "   requirements: ask -- before the first feature, ask the person and wait (skill requirements-interview); $slices slice(s) in docs/brain/plan" ;;
  esac
}

# Where the last session left the app (.mxcli/last-gate.txt, written by tests/gate.sh): a session
# that starts on a built app picks up from here instead of a gate run, or a read of every script, of its own.
last_gate_lines() {
  local staged
  [ -f .mxcli/last-gate.txt ] || return 0
  sed 's/^full:/   gate, last full run:/; s/^last:/   gate, last run:     /' .mxcli/last-gate.txt
  staged="$(grep -c . .mxcli/brain/staged.jsonl 2>/dev/null)"
  [ "${staged:-0}" -gt 0 ] && echo "   $staged requirement(s) staged in .mxcli/brain/staged.jsonl, not yet recorded"
  echo "   this app is built: read only the scripts and tests this request changes; == tests below says what each one covers"
  open_requirements_lines
}

# What earlier requests asked for and the model does not have yet: requirements whose anchors do not
# resolve (`mxcli brain plan` derives it from the model), and open questions. A session per request
# starts from these: one that only saw the gate's DONE skipped a feature the request before had asked
# for (B2B, 2026-10-15). Read with `./mxcli brain brief --slice <slice>`.
open_requirements_lines() {
  local plan
  ls docs/brain/plan/*.md >/dev/null 2>&1 || return 0
  plan="$("$MXCLI" brain plan -p "$MPR" --json 2>/dev/null | "$NODE" -e '
    let t = require("fs").readFileSync(0, "utf8"); t = t.slice(t.indexOf("{"));
    let d; try { d = JSON.parse(t); } catch { process.exit(0); }
    const open = (d.slices || []).filter(s => s.planned > 0 || s.questions > 0)
      .map(s => s.slice + " (" + [s.planned ? s.planned + " not built" : "", s.questions ? s.questions + " open question(s)" : ""].filter(Boolean).join(", ") + ")");
    if (open.length) console.log(open.join("; "));' 2>/dev/null)"
  if [ -n "$plan" ]; then
    echo "   open from earlier requests: $plan -- ./mxcli brain brief --slice <slice> -p $MPR lists them; build what is not built with this request unless it says otherwise, and keep or settle the open questions"
  else
    echo "   every recorded requirement is built (mxcli brain plan)"
  fi
}

app_section() {
  echo "== app"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$APP_PORT" 2>/dev/null)" = "200" ]; then
    echo "   running on http://localhost:$APP_PORT"
  else
    echo "   not running -- $MXCLI run --local -p $MPR --app-port $APP_PORT --watch"
  fi
  [ -f tests/credentials.env ] && echo "   tests/credentials.env present (test sign-in configured)"
  [ -d docs/brain ] && echo "   docs/brain/ present -- read project.md before building"
  requirements_line
  last_gate_lines
  [ -f tools/mdl-checks/VERSION ] && echo "   harness $(cat tools/mdl-checks/VERSION)"
  mdl_check_mxcli_freshness
  mdl_check_install_freshness
  # A pointer, not the text: sessions pipe this output through `head`, and a digest printed
  # here would be cut there.
  if mdl_syntax_digest; then
    echo "   syntax: $MDL_SYNTAX_DIGEST -- the $(grep -c '^## ' "$MDL_SYNTAX_DIGEST") topics every session otherwise looks up; loaded into the session under Claude Code, Cursor, OpenCode and Pi, elsewhere cat it whole once"
  fi
}

# --- Run them in parallel. The file number sets the print order, not the start order. ---
structure_section  > "$WORK/9-structure"  2>&1 &
security_section   > "$WORK/1-security"   2>&1 &
navigation_section > "$WORK/4-navigation" 2>&1 &
tests_section      > "$WORK/2-tests"      2>&1 &
rulebook_section   > "$WORK/3-rulebook"   2>&1 &
app_section        > "$WORK/0-app"        2>&1 &

wait
# Structure last: it is long, and output piped through `head` must keep the rest.
cat "$WORK"/[0-9]-* 2>/dev/null
