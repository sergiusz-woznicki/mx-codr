#!/usr/bin/env bash
# After a tool call that wrote a tests/verify-*.test.sh which has never run: tells the agent to run it
# now, before building what it checks (harness-core newTestNote). Proving a test red after its feature
# exists took two room-booking sessions a break-and-undo per test, 5 and 19 minutes (2026-10-13).
#   bash after-test-written.sh claude   Claude Code PostToolUse: {"hookSpecificOutput": additionalContext}
#   bash after-test-written.sh codex    Codex PostToolUse (shell tool only): the note on stderr, exit 2
#   bash after-test-written.sh cursor   Cursor postToolUse: {"additional_context": ...}, else {}
# Anything else, or nothing to say: exit 0 silently ({} for Cursor).
host="${1:-claude}"
input="$(cat)"
nothing() { [ "$host" = "cursor" ] && printf '{}\n'; exit 0; }
case "$input" in *verify-*.test.sh*) ;; *) nothing ;; esac

# NODE and HOOK_TOOL (hook_tool.cjs, the small jobs: read a field, wrap a message).
. "$(dirname "${BASH_SOURCE[0]}")/hook-env.sh"
cwd="$(printf '%s' "$input" | "$NODE" "$HOOK_TOOL" get cwd 2>/dev/null)"
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true
[ -f tests/gate.sh ] || nothing
note="$(printf '%s' "$input" | "$NODE" "$HOOK_TOOL" new-test 2>/dev/null)"
[ -n "$note" ] || nothing
case "$host" in
  codex) printf '%s\n' "$note" >&2; exit 2 ;;
  cursor) printf '%s' "$note" | "$NODE" "$HOOK_TOOL" wrap additional_context; exit 0 ;;
  *) printf '%s' "$note" | "$NODE" "$HOOK_TOOL" post-context; exit 0 ;;
esac
