#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Bash). Before an `mxcli exec <script>.mdl` runs
# tests/precheck.sh on the scripts it names: the build's own checker on a scratch copy of the
# model. Errors block the exec (exit 2, the reason on stderr reaches the model); anything else
# -- another command, inline MDL, no precheck.sh, mx missing -- lets it through (exit 0).
# The decisions live in before-mxcli-exec-core.sh, shared with the Cursor hook.

# Cheap substring test first: almost no Bash call is an `mxcli exec`.
input="$(cat)"
case "$input" in *"mxcli exec"*|*"mxcli.exe exec"*|*"tests/gate.sh"*|*"gate-boot.log"*|*"runtime.log"*|*mxcli*-c*) ;; *) exit 0 ;; esac

# shellcheck source=before-mxcli-exec-core.sh
. "$(dirname "$0")/before-mxcli-exec-core.sh"

command="$(printf '%s' "$input" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null)"
message="$(hook_sleep_message "$command")"
if [ -n "$message" ]; then
  echo "$message" >&2
  exit 2
fi

inline=()
case "$command" in *mxcli*-c*)
  while IFS= read -r -d '' statement; do inline+=(--inline "$statement"); done < <(inline_mdl "$command") ;;
esac
case "$command" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) [ "${#inline[@]}" -gt 0 ] || exit 0 ;; esac
[ -f tests/precheck.sh ] || exit 0

# Inline MDL has no script to check: let it through.
scripts="$(hook_scripts "$command")"
[ -n "$scripts" ] || [ "${#inline[@]}" -gt 0 ] || exit 0
# `for f in a b; do mxcli exec mdlsource/$f.mdl` hands the hook a literal `$f`: nothing to check.
if printf '%s\n' "$scripts" | grep -q '[$]'; then
  echo "$HOOK_VARIABLE_MESSAGE" >&2
  exit 2
fi

args=()
while IFS= read -r script; do
  [ -n "$script" ] && args+=("$script")
done <<HOOK_SCRIPTS
$scripts
HOOK_SCRIPTS

hook_precheck ${args[@]+"${args[@]}"} ${inline[@]+"${inline[@]}"}
if [ "$HOOK_STATUS" -ne 0 ]; then
  {
    echo "$HOOK_BLOCKED_HEAD"
    steps_before_exec "$command"
    printf '%s\n' "$HOOK_OUT"
  } >&2
  exit 2
fi
# Tell the model the check happened, so it does not run precheck.sh a second time by hand
# (plain stdout of a PreToolUse hook reaches the transcript only, additionalContext the model).
printf '%s\n' "$HOOK_OUT" | head -1 | "$PY" -c 'import json,sys
line = sys.stdin.read().strip()
if line:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": line}}))' 2>/dev/null
exit 0
