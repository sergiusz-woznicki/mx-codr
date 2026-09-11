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
