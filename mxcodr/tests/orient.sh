#!/usr/bin/env bash
# orient.sh -- app facts at session start: app state, security, tests and coverage, lint,
# navigation, module structure. Run by the agent (or you) once per session.
#   bash tests/orient.sh        (env: APP_PORT, default 8081)
# Lookups run in parallel into numbered files. Exit 2 without a .mpr, else 0.
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

# The app's own modules: not System, MyFirstModule or Marketplace (those have a Source).
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
  lint="$("$MXCLI" lint -p "$MPR" 2>&1)"
  printf '%s\n' "$lint" | tail -1
  printf '%s\n' "$lint" | grep -oE '\[(MOD001|REU001|SEC00[0-9]|ARCH00[0-9])\]' | sort | uniq -c | head -8
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
  [ -f tools/mdl-checks/VERSION ] && echo "   harness $(cat tools/mdl-checks/VERSION)"
  mdl_check_install_freshness
} > "$WORK/0-app" 2>&1 &

wait
# Structure last: it is long, and output piped through `head` must keep the rest.
cat "$WORK"/[0-9]-* 2>/dev/null
