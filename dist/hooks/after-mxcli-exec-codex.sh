#!/usr/bin/env bash
# Codex PostToolUse adapter. The shared Claude hook reports failed coverage on
# stdout; Codex intentionally ignores plain stdout for PostToolUse, so translate
# that report into Codex's blocking exit-code contract without changing Claude's
# established behavior.
set -uo pipefail

# Almost every event is not an `mxcli exec`; answer that on the raw text before
# looking for a Python to parse it with (see after-mxcli-exec.sh).
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
case "$command" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) exit 0 ;; esac
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Remember that this Codex session changed the model. The Stop hook uses the
# marker to avoid running the full gate after read-only/question-only turns.
session_id="$(printf '%s' "$input" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)"
if [ -n "$session_id" ]; then
  state_dir="${TMPDIR:-/tmp}/mendix-mdl-codex-hooks"
  safe_session="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-')"
  if [ -n "$safe_session" ] && mkdir -p "$state_dir" 2>/dev/null; then
    printf '%s\n' "$repo_root" > "$state_dir/$safe_session.gate-required"
  fi
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
feedback="$(printf '%s' "$input" | (cd "$repo_root" && bash "$script_dir/after-mxcli-exec.sh"))"
if [ -n "$feedback" ]; then
  printf '%s\n' "$feedback" >&2
  exit 2
fi
exit 0
