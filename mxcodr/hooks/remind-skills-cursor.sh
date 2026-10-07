#!/usr/bin/env bash
# Cursor sessionStart hook (Cursor has no per-prompt context injection): prints {"additional_context": "<rules>"}. Exit 0.
# .cursor/rules/mdl-skills.mdc keeps the rules attached to later requests.
set -uo pipefail

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

# shellcheck source=remind-skills-lib.sh
. "$(dirname "$0")/remind-skills-lib.sh"
mdl_mark_session
mdl_reminder '.cursor/rules/mdl-skills.mdc' \
  'read `test-first-delivery` (`.ai-context/skills/<name>/SKILL.md`)' \
  '(a hook runs `tests/precheck.sh` for you -- mx check on a copy; do not call it by hand)' \
  | "$NODE" "$HOOK_TOOL" wrap additional_context
