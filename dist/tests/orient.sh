#!/usr/bin/env bash
# What is in this app, and what state is it in -- in one call, at session start.
#
#   bash tests/orient.sh
#
# A session that starts by reading the brain, the structure, the security matrix and
# the existing tests spends four or five minutes and twenty shell calls establishing
# facts that cost milliseconds each. The lookups are independent, so they run
# concurrently; the whole thing is about a second.
#
# Facts only. What to build with them is the session's job, and `docs/brain/` is
# still where the decisions live -- read it, this does not replace it.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
cd "$APP_DIR"
. "$HARNESS_DIR/portable.sh"
MPR="$(ls -1 *.mpr 2>/dev/null | head -1)"
[ -n "$MPR" ] || { echo "no .mpr in $APP_DIR" >&2; exit 2; }
APP_PORT="${APP_PORT:-8081}"
WORK="$(mdl_tmpdir mdl-orient)"
trap 'rm -rf "$WORK"' EXIT

user_modules() {
  "$MXCLI" -p "$MPR" --json -c "SHOW MODULES" 2>/dev/null \
    | "$PY" -c 'import json,sys
for row in json.load(sys.stdin):
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System","MyFirstModule"):
        print(row["Module"])' 2>/dev/null
}

{
  echo "== structure (this app's own modules; System and Atlas are not listed)"
  for module in $(user_modules); do
    "$MXCLI" -p "$MPR" -c "SHOW STRUCTURE DEPTH 2 IN $module" 2>&1 | head -60
  done
} > "$WORK/9-structure" 2>&1 &

{
  echo "== security"
  "$MXCLI" -p "$MPR" -c "SHOW PROJECT SECURITY" 2>&1 | grep -iE 'security level|demo users|guest|user roles'
  "$MXCLI" -p "$MPR" -c "SHOW USER ROLES" 2>&1 | grep -E '^\|' | head -10
} > "$WORK/1-security" 2>&1 &

{
  echo "== navigation"
  "$MXCLI" -p "$MPR" -c "SHOW NAVIGATION HOMES" 2>&1 | head -10
  "$MXCLI" -p "$MPR" -c "SHOW NAVIGATION MENU" 2>&1 | head -15
} > "$WORK/4-navigation" 2>&1 &

{
  echo "== tests already here (and what each one covers)"
  for script in tests/verify-*.test.sh; do
    [ -f "$script" ] || continue
    printf '   %-42s %s\n' "$(basename "$script")" \
      "$(grep -m1 '^# covers:' "$script" | sed 's/^# covers: //')"
  done
  echo "== coverage"
  if [ -f tools/mdl-checks/check_test_coverage.py ]; then
    for module in $(user_modules); do
      printf '   %-20s %s\n' "$module" "$("$PY" tools/mdl-checks/check_test_coverage.py . "$module" 2>&1 | tail -1)"
    done
  fi
} > "$WORK/2-tests" 2>&1 &

{
  echo "== lint (the project's own rules included)"
  "$MXCLI" lint -p "$MPR" 2>&1 | tail -1
  "$MXCLI" lint -p "$MPR" 2>&1 | grep -oE '\[(MOD001|REU001|SEC00[0-9]|ARCH00[0-9])\]' | sort | uniq -c | head -8
} > "$WORK/3-lint" 2>&1 &

{
  echo "== app"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$APP_PORT" 2>/dev/null)" = "200" ]; then
    echo "   running on http://localhost:$APP_PORT"
  else
    echo "   not running -- $MXCLI run --local -p $MPR --app-port $APP_PORT --watch"
  fi
  [ -f tests/credentials.env ] && echo "   tests/credentials.env present (test sign-in configured)"
  [ -d docs/brain ] && echo "   docs/brain/ present -- read project.md before building"
} > "$WORK/0-app" 2>&1 &

wait
# 0-app first, 9-structure last: the structure dump is the long one, and a
# session that pipes this through `head` must not lose the rest behind it.
cat "$WORK"/[0-9]-* 2>/dev/null
