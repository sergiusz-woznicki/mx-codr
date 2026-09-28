#!/usr/bin/env bash
# Cursor `beforeShellExecution` hook. Cursor sends {"command": ..., "cwd": ..., ...} and reads
# back {"permission": "allow"|"deny", "userMessage": ..., "agentMessage": ...}. Before an
# `mxcli exec <script>.mdl` this runs tests/precheck.sh (the build's own checker on a scratch
# copy of the model) and denies the exec when it fails, with the errors as the agent's message.
# Everything else is allowed, including when the check cannot run.

input="$(cat)"
allow() { printf '{"permission":"allow"}\n'; exit 0; }
case "$input" in *"mxcli exec"*|*"mxcli.exe exec"*|*harness.env*|*tests/*|*mdl-checks*|*lint-rules*|*hooks.json*|*settings.local.json*|*mxcli*-c*) ;; *) allow ;; esac

mdl_find_python() {
  local candidate
  for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  # The python.org installer (also via winget) does not add Python to PATH; search its install dirs too.
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

# Cursor puts the command at the top level; a Claude-shaped payload has it under tool_input.
command="$(printf '%s' "$input" | "$PY" -c 'import json,sys
d = json.load(sys.stdin)
print(d.get("command") or d.get("tool_input", {}).get("command", ""))' 2>/dev/null)"
cwd="$(printf '%s' "$input" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("cwd") or "")' 2>/dev/null)"
[ -z "$cwd" ] || cd "$cwd" 2>/dev/null || allow
# tests/harness.env is the person's: the same guard as the other hosts (guard-harness-env.sh).
guard="$(dirname "$0")/guard-harness-env.sh"
if [ -f "$guard" ]; then
  why="$(printf '%s' "$command" | "$PY" -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.stdin.read()}}))' \
    | bash "$guard" 2>&1 >/dev/null)" || {
    printf '%s' "$why" | "$PY" -c 'import json,sys; m=sys.stdin.read(); print(json.dumps({"permission": "deny", "userMessage": "Blocked a change to the gate switches in tests/harness.env.", "agentMessage": m}))'
    exit 0
  }
fi
# MDL given to mxcli with -c that changes the model (CREATE, ALTER, DROP, GRANT, REVOKE, MOVE,
# RENAME), NUL-separated. It went round the precheck: one broken access rule written that way
# blocked every later exec with an error that was not in its script.
inline_mdl() {
  printf '%s' "$1" | "$PY" -c 'import re, shlex, sys
text = sys.stdin.read()
try:
    words = shlex.split(text)
except ValueError:
    sys.exit(0)
seen_mxcli = False
for i, word in enumerate(words):
    if re.search(r"(^|/)mxcli(\.exe)?$", word):
        seen_mxcli = True
    elif word in ("|", ";", "&&", "||"):
        seen_mxcli = False
    elif seen_mxcli and word == "-c" and i + 1 < len(words):
        if re.match(r"\s*(create|alter|drop|grant|revoke|move|rename)\b", words[i + 1], re.I):
            sys.stdout.write(words[i + 1] + "\0")' 2>/dev/null
}
inline=()
case "$command" in *mxcli*-c*)
  while IFS= read -r -d '' statement; do inline+=(--inline "$statement"); done < <(inline_mdl "$command") ;;
esac
case "$command" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) [ "${#inline[@]}" -gt 0 ] || allow ;; esac
[ -f tests/precheck.sh ] || allow

scripts="$(printf '%s' "$command" | "$PY" -c 'import glob, shlex, sys
text = sys.stdin.read()
try:
    words = shlex.split(text)
except ValueError:
    words = text.split()
LIMIT = 200
seen = set()
for word in words:
    if not word.endswith(".mdl") or word in seen:
        continue
    seen.add(word)
    matches = []
    if any(c in word for c in "*?[") and word.count("*") <= 4:
        for i, match in enumerate(sorted(glob.iglob(word))):
            if i >= LIMIT:
                matches = []
                break
            matches.append(match)
    print("\n".join(matches) if matches else word)' 2>/dev/null)"
[ -n "$scripts" ] || [ "${#inline[@]}" -gt 0 ] || allow

args=()
while IFS= read -r script; do
  [ -n "$script" ] && args+=("$script")
done <<HOOK_SCRIPTS
$scripts
HOOK_SCRIPTS

out="$(bash tests/precheck.sh ${args[@]+"${args[@]}"} ${inline[@]+"${inline[@]}"} 2>&1)"
if [ $? -ne 0 ]; then
  printf '%s' "$out" | "$PY" -c 'import json,sys
out = sys.stdin.read()
print(json.dumps({"permission": "deny",
    "userMessage": "mxcli exec blocked: the script would break the build (see the agent message).",
    "agentMessage": "Blocked: that exec would break the build (mx check on a copy of the model, nothing changed). Fix the script and exec again:\n" + out}))'
  exit 0
fi
allow
