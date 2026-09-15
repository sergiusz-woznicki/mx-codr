#!/usr/bin/env bash
# Why is that row not on the page? -- every fact worth having, in one call.
#
#   bash tests/diagnose.sh                     # the standard picture
#   bash tests/diagnose.sh Invoice             # plus access rules and XPath for one entity
#   bash tests/diagnose.sh Invoice demo_customer   # plus that user's roles
#
# This exists because diagnosing a red test used to cost three or four round trips
# (row counts, then the user link, then the access rules), and a shell round trip in
# an agent session has a 1.9s median while the queries themselves cost 0.02s. The
# lookups are independent, so they run concurrently and the whole thing is ~1s.
#
# Facts, not judgement: nothing here decides what is wrong, it just stops the model
# guessing about state it can cheaply know.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
cd "$APP_DIR"
. "$HARNESS_DIR/portable.sh"
MPR="$(ls -1 *.mpr 2>/dev/null | head -1)"
[ -n "$MPR" ] || { echo "no .mpr in $APP_DIR" >&2; exit 2; }
ENTITY="${1:-}"
USER_NAME="${2:-}"
RUNTIME_LOG="${RUNTIME_LOG:-$APP_DIR/.mxcli/runtime.log}"
WORK="$(mdl_tmpdir mdl-diagnose)"
trap 'rm -rf "$WORK"' EXIT

module_list() {
  "$MXCLI" -p "$MPR" --json -c "SHOW MODULES" 2>/dev/null \
    | "$PY" -c 'import json,sys
for row in json.load(sys.stdin):
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System","MyFirstModule"):
        print(row["Module"])' 2>/dev/null
}

# --- every fact as its own background job ------------------------------------
{
  echo "== security"
  "$MXCLI" -p "$MPR" -c "SHOW PROJECT SECURITY" 2>&1 | grep -iE 'security level|demo users|guest|admin user'
  "$MXCLI" -p "$MPR" -c "SHOW DEMO USERS" 2>&1 | grep -E '^\|' | head -12
} > "$WORK/1-security" 2>&1 &

{
  echo "== rows in the database"
  # OQL reads through the running runtime: with the app down every count comes back
  # empty, and "0 invoices" would read as missing data rather than a missing app.
  probe="$("$MXCLI" oql -p "$MPR" --json "SELECT COUNT(*) AS n FROM System.User" 2>&1)"
  case "$probe" in
    *'"n"'*) ;;
    *) echo "   the runtime is not answering, so row counts are unavailable"
       echo "   (start it: $MXCLI run --local -p $MPR --app-port ${APP_PORT:-8081} --watch)"
       exit 0 ;;
  esac
  for module in $(module_list); do
    # SHOW ENTITIES reports the qualified name in "Entity" and the kind in "Type".
    "$MXCLI" -p "$MPR" --json -c "SHOW ENTITIES IN $module" 2>/dev/null \
      | "$PY" -c 'import json,sys
for row in json.load(sys.stdin):
    name = row.get("Entity") or ""
    if name and "non-persistent" not in (row.get("Type") or "").lower():
        print(name)' 2>/dev/null | while read -r entity; do
        count="$("$MXCLI" oql -p "$MPR" --json "SELECT COUNT(*) AS n FROM $entity" 2>/dev/null \
          | "$PY" -c '
import json, sys
text = sys.stdin.read()
start = text.find("[")
try:
    rows, _ = json.JSONDecoder().raw_decode(text[start:])
except Exception:
    rows = []
print(rows[0].get("n", "?") if rows else 0)
')"
        printf "   %-40s %s\n" "$entity" "${count:-?}"
      done
  done
  printf "   %-40s %s\n" "System.User" "$("$MXCLI" oql -p "$MPR" --json "SELECT Name FROM System.User" 2>/dev/null | grep -c '"Name"')"
} > "$WORK/2-rows" 2>&1 &

{
  echo "== live sessions (a developer/trial licence caps them)"
  curl -s -m 5 -X POST "http://localhost:${ADMIN_PORT:-8090}/" \
    -H "X-M2EE-Authentication: $(printf '%s' "${ADMIN_PASSWORD:-mxcli-local-dev}" | base64)" \
    -H 'Content-Type: application/json' -d '{"action":"get_logged_in_user_names"}' 2>/dev/null \
    | "$PY" -c 'import json,sys
try:
    f=json.load(sys.stdin)["feedback"]
    print("   signed in: %s (%s)" % (", ".join(f.get("users") or []) or "nobody", f.get("count", 0)))
except Exception:
    print("   admin port did not answer")' 2>/dev/null
  if [ -f "$RUNTIME_LOG" ]; then
    refusals="$(tail -400 "$RUNTIME_LOG" | grep -c 'Maximum number of sessions exceeded')"
    [ "$refusals" != "0" ] && echo "   session-cap refusals in the last 400 log lines: $refusals"
  fi
} > "$WORK/3-sessions" 2>&1 &

{
  echo "== last runtime errors"
  if [ -f "$RUNTIME_LOG" ]; then
    grep -E ' (ERROR|CRITICAL) ' "$RUNTIME_LOG" | tail -5 | cut -c1-160
  else
    echo "   no runtime log at $RUNTIME_LOG"
  fi
} > "$WORK/4-errors" 2>&1 &

if [ -n "$ENTITY" ]; then
  {
    echo "== access on $ENTITY (row-level XPath is what hides rows from a role)"
    for module in $(module_list); do
      "$MXCLI" -p "$MPR" -c "SHOW ACCESS ON ENTITY $module.$ENTITY" 2>/dev/null | head -25
    done
    echo "== associations of $ENTITY (a missing link looks exactly like a missing row)"
    for module in $(module_list); do
      "$MXCLI" -p "$MPR" -c "SHOW ASSOCIATIONS IN $module" 2>/dev/null | grep -i "$ENTITY" | head -10
    done
  } > "$WORK/5-access" 2>&1 &
fi

if [ -n "$USER_NAME" ]; then
  {
    echo "== $USER_NAME"
    "$MXCLI" oql -p "$MPR" --json \
      "SELECT u/Name AS UserName, r/Name AS RoleName FROM System.User AS u
       JOIN u/System.UserRoles/System.UserRole AS r WHERE u/Name = '$USER_NAME'" 2>&1 | head -20
  } > "$WORK/6-user" 2>&1 &
fi

wait
cat "$WORK"/[0-9]-* 2>/dev/null

# Last, because it is usually silent: a local database a deploy build left
# half-written, or a lock a killed runtime left behind.
mdl_check_local_database
