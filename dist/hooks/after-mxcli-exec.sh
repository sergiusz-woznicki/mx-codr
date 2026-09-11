#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash). After any `mxcli exec` that wrote the model,
# run the test-coverage check for every user module and feed the result back as
# context. The model still decides what to do with it -- but it can no longer
# claim not to have known.

# This hook runs after EVERY Bash tool call, and almost none of them are an
# `mxcli exec`. So the cheap question comes first, on the raw event, before any
# Python is looked for: a plain substring test costs nothing, the Python probe
# below runs up to three interpreters. (A false positive here -- the words in a
# comment, say -- only means the precise check below runs; a miss is impossible,
# since the command text is inside the event.)
input="$(cat)"
case "$input" in *"mxcli exec"*) ;; *) exit 0 ;; esac

# Windows (Git Bash) has no `python3`, and a `python3.exe` stub that opens the
# Microsoft Store instead of running anything is common, so each candidate is asked
# to run before it is believed. Inlined rather than sourced: a hook has to work with
# nothing else on disk but itself.
mdl_find_python() {
  local candidate
  for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  # The python.org installer leaves "Add python.exe to PATH" unticked by default
  # and winget accepts that default, so a Windows box can hold a working Python
  # that no shell can see. Observed on a clean Windows 11 VM.
  local local_app="${LOCALAPPDATA:-}"
  local_app="${local_app//\\//}"
  for candidate in \
      "$local_app/Programs/Python"/Python3*/python.exe \
      "$local_app/Programs/Python/Launcher/py.exe" \
      "/c/Program Files"/Python3*/python.exe \
      "/c/Program Files (x86)"/Python3*/python.exe; do
    [ -x "$candidate" ] || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
PY="$(mdl_find_python || true)"
PY="${PY:-python3}"

command="$(printf '%s' "$input" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null)"
# Only a real model write. Matching read-only queries too (mxcli -c "SHOW ...")
# ran the coverage checker after every lookup a session made, for nothing.
case "$command" in *"mxcli exec"*) ;; *) exit 0 ;; esac
# --- does the running app still match the model? -----------------------------
# Entity, association, enumeration and security changes do NOT hot-apply: the
# runtime keeps serving the model it booted with, so a correct fix reads as a
# failing feature -- one session chased that twice. Microflow, page, nanoflow and
# snippet changes DO hot-apply under `mxcli run --watch`, in about two seconds,
# and restarting for those costs ~35s each -- another session did it ten times.
# One line, saying which of the two this exec was.
_app_running=0
for _port in "${APP_PORT:-8081}" 8080; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://localhost:$_port/" 2>/dev/null)" = "200" ] \
    && { _app_running=1; break; }
done
if [ "$_app_running" = "1" ]; then
  # What the exec actually carried: the .mdl files named on the command line, or
  # the inline text when there are none.
  _changed=""
  for _word in $command; do
    case "$_word" in
      *.mdl) [ -f "$_word" ] && _changed="$_changed
$(cat "$_word" 2>/dev/null)" ;;
    esac
  done
  [ -n "$_changed" ] || _changed="$command"
  # Document-level access -- `grant execute on microflow`, `grant view on page` --
  # is dropped first: `describe microflow` prints those grants under almost every
  # flow, so counting them made nearly every exec look like a security change.
  # What actually needs a reboot is the schema (entities, associations,
  # enumerations), the row-level rules on an entity, the roles behind them, and
  # runtime settings.
  if printf '%s' "$_changed" \
     | grep -viE '(grant|revoke)[[:space:]]+(execute|view)[[:space:]]+on[[:space:]]+(microflow|nanoflow|page|snippet)' \
     | grep -qiE '(create|alter|drop)[[:space:]]+(or[[:space:]]+(modify|replace)[[:space:]]+)?((non-)?persistent[[:space:]]+)?(entity|association|enumeration)|alter[[:space:]]+project[[:space:]]+security|alter[[:space:]]+settings|(grant|revoke)[[:space:]]|(create|drop)[[:space:]]+(or[[:space:]]+modify[[:space:]]+)?(module[[:space:]]+role|user[[:space:]]+role|demo[[:space:]]+user)'; then
    printf 'That exec touched entities, associations, enumerations or security, which do NOT hot-apply: the app is still serving the model it booted with, so a test failing now says nothing about the feature. Restart first: bash tests/gate.sh --restart\n'
  else
    printf 'That exec changed logic and screens only -- `mxcli run --watch` hot-applies those in about two seconds, so no restart is needed. Run the test: bash tests/gate.sh --only <feature>\n'
  fi
fi

[ -f tools/mdl-checks/check_test_coverage.py ] || exit 0
mpr="$(ls -1 *.mpr 2>/dev/null | head -1)"; [ -n "$mpr" ] || exit 0

MXCLI="./mxcli"; [ -x "$MXCLI" ] || { [ -x "./mxcli.exe" ] && MXCLI="./mxcli.exe"; }
modules="$("$MXCLI" -p "$mpr" --json -c "SHOW MODULES" 2>/dev/null \
  | "$PY" -c 'import json,sys
for row in json.load(sys.stdin):
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System","MyFirstModule"):
        print(row["Module"])' 2>/dev/null)"
[ -n "$modules" ] || exit 0

for module in $modules; do
  out="$("$PY" tools/mdl-checks/check_test_coverage.py . "$module" 2>&1)" || true
  case "$out" in
    FAIL*) printf 'Test coverage after that mxcli exec, module %s:\n%s\nEvery page and ACT_ microflow needs a tests/verify-*.test.sh with a `# covers:` line naming it (skill: test-first-delivery).\n' "$module" "$out" ;;
  esac
done
exit 0
