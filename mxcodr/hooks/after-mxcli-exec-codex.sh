#!/usr/bin/env bash
# Codex PostToolUse hook (matcher ^Bash$): after an `mxcli exec`, marks the session for stop-gate-codex.sh
# and runs after-mxcli-exec.sh. Its output goes to stderr with exit 2 (Codex feeds it back to the model);
# exit 0 silently otherwise, since Codex ignores plain PostToolUse stdout.
set -uo pipefail

# Cheap substring test first: almost no event is an `mxcli exec`.
input="$(cat)"
case "$input" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) exit 0 ;; esac

# Prints a node that runs; inlined so the hook is self-contained (same as tests/portable.sh).
mdl_find_node() {
  if command -v node >/dev/null 2>&1; then
    printf 'node\n'
    return 0
  fi
  # The Node.js installer (also via winget) puts node on PATH only for shells started after it.
  local local_app="${LOCALAPPDATA:-}" candidate
  local_app="${local_app//\\//}"
  for candidate in "/c/Program Files/nodejs/node.exe" "$local_app/Programs/nodejs/node.exe"; do
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
NODE="$(mdl_find_node || true)"
NODE="${NODE:-node}"
# hook_tool.cjs holds the small jobs (read a field, wrap a message); installed one directory up
# from this hook, in the bundle under checks/. An absolute path: the hook may cd into the project.
HOOK_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hook_tool.cjs"
[ -f "$HOOK_TOOL" ] || HOOK_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../checks" 2>/dev/null && pwd)/hook_tool.cjs"

command="$(printf '%s' "$input" | "$NODE" "$HOOK_TOOL" command 2>/dev/null)"
case "$command" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) exit 0 ;; esac
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Marker: the stop hook runs the gate only for sessions that changed the model.
session_id="$(printf '%s' "$input" | "$NODE" "$HOOK_TOOL" get-default session_id 2>/dev/null)"
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
