#!/usr/bin/env bash
# Cursor `beforeShellExecution` hook. Cursor sends {"command": ..., "cwd": ..., ...} and reads
# back {"permission": "allow"|"deny", "userMessage": ..., "agentMessage": ...}. Before an
# `mxcli exec <script>.mdl` this runs tests/precheck.sh (the build's own checker on a scratch
# copy of the model) and denies the exec when it fails, with the errors as the agent's message.
# Everything else is allowed, including when the check cannot run.
# The decisions live in before-mxcli-exec-core.sh, shared with the Claude/Codex hook.

input="$(cat)"
allow() { printf '{"permission":"allow"}\n'; exit 0; }
case "$input" in *"mxcli exec"*|*"mxcli.exe exec"*|*harness.env*|*paths-baseline*|*write-baseline*|*tests/*|*mdl-checks*|*lint-rules*|*hooks.json*|*settings.local.json*|*mxcli*-c*|*"mxcli marketplace"*|*"mxcli.exe marketplace"*|*"mxcli catalog"*|*"mxcli.exe catalog"*) ;; *) allow ;; esac

# shellcheck source=before-mxcli-exec-core.sh
. "$(dirname "$0")/before-mxcli-exec-core.sh"

# deny <agent message> -- Cursor's answer for a blocked call.
deny() {
  printf '%s' "$1" | "$NODE" "$HOOK_TOOL" deny
  exit 0
}

# Cursor puts the command at the top level; a Claude-shaped payload has it under tool_input.
command="$(printf '%s' "$input" | "$NODE" "$HOOK_TOOL" cursor-command 2>/dev/null)"
cwd="$(printf '%s' "$input" | "$NODE" "$HOOK_TOOL" get cwd 2>/dev/null)"
[ -z "$cwd" ] || cd "$cwd" 2>/dev/null || allow
# tests/harness.env is the person's: the same guard as the other hosts (guard-harness-env.sh).
guard="$(dirname "$0")/guard-harness-env.sh"
if [ -f "$guard" ]; then
  why="$(printf '%s' "$command" | "$NODE" "$HOOK_TOOL" bash-payload \
    | bash "$guard" 2>&1 >/dev/null)" || {
    printf '%s' "$why" | "$NODE" "$HOOK_TOOL" guard-deny
    exit 0
  }
fi
# The same two rules the Claude Code hook has; this copy had lost them (audit of 2026-10-04).
message="$(hook_sleep_message "$command")"
[ -z "$message" ] || deny "$message"
# The app needs a Marketplace module and mxcli is not logged in: wait for the person's login.
hook_marketplace_wait "$command" || deny "$HOOK_MARKETPLACE_OUT"
inline=()
case "$command" in *mxcli*-c*)
  while IFS= read -r -d '' statement; do inline+=(--inline "$statement"); done < <(inline_mdl "$command") ;;
esac
case "$command" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) [ "${#inline[@]}" -gt 0 ] || allow ;; esac
[ -f tests/precheck.sh ] || allow

scripts="$(hook_scripts "$command")"
[ -n "$scripts" ] || [ "${#inline[@]}" -gt 0 ] || allow
# `for f in a b; do mxcli exec mdlsource/$f.mdl` hands the hook a literal `$f`: nothing to check.
if printf '%s\n' "$scripts" | grep -q '[$]'; then deny "$HOOK_VARIABLE_MESSAGE"; fi

args=()
while IFS= read -r script; do
  [ -n "$script" ] && args+=("$script")
done <<HOOK_SCRIPTS
$scripts
HOOK_SCRIPTS
written="$(script_written_before_exec "$command" ${args[@]+"${args[@]}"})"
[ -z "$written" ] || deny "$written"

hook_precheck ${args[@]+"${args[@]}"} ${inline[@]+"${inline[@]}"}
if [ "$HOOK_STATUS" -ne 0 ]; then
  note="$(steps_before_exec "$command")"
  [ -n "$note" ] && HOOK_OUT="$note"$'\n'"$HOOK_OUT"
  deny "$HOOK_BLOCKED_HEAD"$'\n'"$HOOK_OUT"
fi
allow
