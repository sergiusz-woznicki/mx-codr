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
case "$input" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) exit 0 ;; esac

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
case "$command" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) exit 0 ;; esac
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
  # What the exec actually carried. The command is split the way a shell splits it
  # -- by Python's shlex, which parses and never runs anything -- so a quoted path is
  # a path, not a word with quote marks on it, and a glob is expanded. Every .mdl it
  # names is read. A name that cannot be opened means the hook does not know what
  # changed, and it says so instead of guessing: a wrong "no restart needed" is what
  # sent one session chasing a correct fix for twenty minutes.
  _words="$(printf '%s' "$command" | "$PY" -c 'import glob, shlex, sys
text = sys.stdin.read()
try:
    words = shlex.split(text)
except ValueError:
    words = text.split()
# A hook runs after every terminal command, so the expansion is bounded: a pattern
# like /*/*/*/*/* took 14 seconds and returned 120k paths on this machine, and the
# hook has no timeout of its own on every host.
LIMIT = 200
for word in words:
    matches = []
    if any(c in word for c in "*?[") and word.count("*") <= 4:
        for i, match in enumerate(sorted(glob.iglob(word))):
            if i >= LIMIT:
                matches = []          # too broad to be a list of edited scripts
                break
            matches.append(match)
    print("\n".join(matches) if matches else word)' 2>/dev/null)"
  [ -n "$_words" ] || _words="$(printf '%s\n' $command)"
  _changed=""; _unreadable=""; _named=0
  while IFS= read -r _word; do
    case "$_word" in
      *.mdl)
        _named=1
        if [ -f "$_word" ]; then
          _changed="$_changed
$(cat "$_word" 2>/dev/null)"
        else
          _unreadable="$_unreadable $_word"
        fi ;;
    esac
  done <<HOOK_WORDS
$_words
HOOK_WORDS
  # No script named: the MDL, if any, is in the command itself (a heredoc on stdin).
  [ "$_named" = "1" ] || _changed="$command"

  # A project booted by MDL_BOOT_COMMAND (run-app.sh, a deploy build) is not under
  # `mxcli run --watch`, so nothing it serves hot-applies.
  _custom_boot=""
  if [ -n "${MDL_BOOT_COMMAND:-}" ] \
     || grep -qE '^[[:space:]]*(export[[:space:]]+)?MDL_BOOT_COMMAND=' tests/harness.env 2>/dev/null; then
    _custom_boot=1
  fi

  # Document-level access -- `grant execute on microflow`, `grant view on page` --
  # is dropped first: `describe microflow` prints those grants under almost every
  # flow, so counting them made nearly every exec look like a security change.
  # What actually needs a reboot is the schema (entities, associations,
  # enumerations), a module created or dropped (measured: the watched app rebuilds
  # and the next test times out), the row-level rules on an entity, the roles behind
  # them, and runtime settings.
  if printf '%s' "$_changed" \
     | grep -viE '(grant|revoke)[[:space:]]+(execute|view)[[:space:]]+on[[:space:]]+(microflow|nanoflow|page|snippet)' \
     | grep -qiE '(create|alter|drop)[[:space:]]+(or[[:space:]]+(modify|replace)[[:space:]]+)?((non-)?persistent[[:space:]]+)?(entity|association|enumeration)|alter[[:space:]]+project[[:space:]]+security|alter[[:space:]]+settings|(create|drop)[[:space:]]+module[[:space:]]|(grant|revoke)[[:space:]]|(create|drop)[[:space:]]+(or[[:space:]]+modify[[:space:]]+)?(module[[:space:]]+role|user[[:space:]]+role|demo[[:space:]]+user)'; then
    printf 'That exec touched entities, associations, enumerations, modules or security, which do NOT hot-apply: the app is still serving the model it booted with, so a test failing now says nothing about the feature. Restart first: bash tests/gate.sh --restart --only <feature>\n'
  elif [ -n "$_unreadable" ] || ! printf '%s' "$_changed" | grep -qiE '(create|alter|drop|grant|revoke|move|rename)[[:space:]]'; then
    if [ -n "$_unreadable" ]; then _why="could not open${_unreadable}"; else _why="no script path or MDL in the command"; fi
    printf 'Could not tell what that exec changed (%s). If it touched entities, associations, enumerations or security, the app does not have it yet: bash tests/gate.sh --restart --only <feature>. Logic and screen changes need no restart: bash tests/gate.sh --only <feature>\n' "$_why"
  elif [ -n "$_custom_boot" ]; then
    printf 'That exec changed logic and screens only, but this project boots with MDL_BOOT_COMMAND rather than `mxcli run --watch`, so nothing hot-applies. Restart before trusting a test: bash tests/gate.sh --restart --only <feature>\n'
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

# All modules in one call, so a test covering another module's page is not reported
# as stale.
# shellcheck disable=SC2086
out="$("$PY" tools/mdl-checks/check_test_coverage.py . $modules 2>&1)" || true
case "$out" in
  *FAIL*) printf 'Test coverage after that mxcli exec:\n%s\nEvery page and ACT_ microflow needs a tests/verify-*.test.sh with a `# covers:` line naming it (skill: test-first-delivery).\n' "$out" ;;
esac
exit 0
