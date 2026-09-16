#!/usr/bin/env bash
# Codex Stop hook. A session that ran `mxcli exec` may not finish until the full
# project gate reports its positive DONE line. Exit 2 asks Codex to continue
# working with stderr as the continuation instruction.
set -uo pipefail

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


input="$(cat)"
session_id="$(printf '%s' "$input" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)"
[ -n "$session_id" ] || exit 0

state_dir="${TMPDIR:-/tmp}/mendix-mdl-codex-hooks"
safe_session="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-')"
[ -n "$safe_session" ] || exit 0
marker="$state_dir/$safe_session.gate-required"
[ -f "$marker" ] || exit 0

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
expected_root="$(cat "$marker" 2>/dev/null || true)"
[ -z "$expected_root" ] || [ "$expected_root" = "$repo_root" ] || exit 0

if [ ! -f "$repo_root/tests/gate.sh" ]; then
  echo "The model changed through mxcli exec, but tests/gate.sh is missing; restore the project gate before reporting completion." >&2
  exit 2
fi

output="$(cd "$repo_root" && bash tests/gate.sh 2>&1)"
status=$?
if [ "$status" -eq 0 ] && printf '%s\n' "$output" | grep -Fq 'DONE — every check passed'; then
  rm -f "$marker"
  exit 0
fi

printf 'The project gate has not passed. Fix the failures and run it again before reporting completion:\n%s\n' "$output" >&2
exit 2
