#!/usr/bin/env bash
# Cursor postToolUse hook. afterShellExecution sees the command and its output but
# is fire-and-forget -- it cannot talk back to the agent -- so coverage feedback
# goes through postToolUse, which returns additional_context that lands in the
# conversation.
#
# postToolUse supports no matcher, so this fires after every tool call and filters
# for `mxcli exec` itself. The filter reads the whole stdin payload rather than one
# named field: the terminal command sits in tool_input, whose shape differs between
# Cursor's shell tool versions, and a missed field would silently disable coverage.
#
# Output contract: JSON on stdout, exit 0. Exit codes do not carry meaning here.
set -uo pipefail

# Almost every event is not an `mxcli exec`; answer that on the raw text before
# looking for a Python to parse it with (see after-mxcli-exec.sh).
input="$(cat)"
case "$input" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) printf '{}\n'; exit 0 ;; esac

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


# Resolved before anything changes directory: BASH_SOURCE may be relative, and the
# cwd moves to the project below.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

emit() {  # emit "<text>" -- or nothing at all when there is nothing to say
  [ -n "${1:-}" ] || { printf '{}\n'; exit 0; }
  printf '%s' "$1" | "$PY" -c 'import json,sys; print(json.dumps({"additional_context": sys.stdin.read().strip()}))'
  exit 0
}

cwd="$(printf '%s' "$input" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd") or "")
except Exception: print("")' 2>/dev/null)"
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null || true
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" 2>/dev/null || true

# Remember that this session changed the model, so the stop hook knows whether the
# full gate is owed. Keyed by conversation, and the file records the project, so a
# marker from another checkout cannot gate this one.
conversation="$(printf '%s' "$input" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("conversation_id") or "")
except Exception: print("")' 2>/dev/null)"
if [ -n "$conversation" ]; then
  state_dir="${TMPDIR:-/tmp}/mendix-mdl-cursor-hooks"
  safe="$(printf '%s' "$conversation" | tr -cd 'A-Za-z0-9._-')"
  if [ -n "$safe" ] && mkdir -p "$state_dir" 2>/dev/null; then
    printf '%s\n' "$repo_root" > "$state_dir/$safe.gate-required"
  fi
fi

[ -f "$script_dir/after-mxcli-exec.sh" ] || emit ""

# The shared script reads a Claude-shaped payload and reports failures on stdout.
# Hand it the command it expects rather than duplicating the coverage logic.
# The real command, so the shared hook can tell a logic change from an entity or
# security change. Cursor's shell tool has moved tool_input's shape around, so it
# is lifted out of the raw payload rather than read from a named field.
# Found by walking the parsed payload for the string that holds the exec, then
# re-encoded with json.dumps -- the old grep stopped at the first escaped quote, so
# `./mxcli exec "x.mdl"` arrived as `./mxcli exec \` and printf built invalid JSON.
_payload="$(printf '%s' "$input" | "$PY" -c 'import json, sys
def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
try:
    data = json.load(sys.stdin)
except Exception:
    data = None
command = next((s for s in strings(data) if "mxcli exec" in s or "mxcli.exe exec" in s), "mxcli exec")
print(json.dumps({"tool_input": {"command": command.replace("\\", "/")}}))' 2>/dev/null)"
[ -n "$_payload" ] || _payload='{"tool_input":{"command":"mxcli exec"}}'
feedback="$(printf '%s' "$_payload" | bash "$script_dir/after-mxcli-exec.sh" 2>/dev/null)"
emit "$feedback"
