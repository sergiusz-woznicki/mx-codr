#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Bash). Before an `mxcli exec <script>.mdl` runs
# tests/precheck.sh on the scripts it names: the build's own checker on a scratch copy of the
# model. Errors block the exec (exit 2, the reason on stderr reaches the model); anything else
# -- another command, inline MDL, no precheck.sh, mx missing -- lets it through (exit 0).

# Cheap substring test first: almost no Bash call is an `mxcli exec`.
input="$(cat)"
case "$input" in *"mxcli exec"*|*"mxcli.exe exec"*|*"tests/gate.sh"*|*"gate-boot.log"*|*"runtime.log"*|*mxcli*-c*) ;; *) exit 0 ;; esac

# Prints the first Python that actually runs (Windows may have only a Store stub); inlined so the hook is self-contained.
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

command="$(printf '%s' "$input" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null)"
# `...; sleep 12; bash tests/gate.sh`: the gate waits for the runtime itself.
if printf '%s' "$command" | grep -qE '(^|[^[:alnum:]_])sleep[[:space:]]+[0-9]' \
   && printf '%s' "$command" | grep -qE 'tests/gate\.sh|gate-boot\.log|runtime\.log'; then
  echo "Blocked: drop the \`sleep\` -- tests/gate.sh waits for the runtime and for --watch to apply the latest change itself, and says so; a hand-rolled wait only adds seconds. Run the same command without it." >&2
  exit 2
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
# steps_before_exec <command> -- prints a note when the command does more than set variables or cd
# before its `mxcli exec`: a blocked command runs none of it. GLM sent `python3 <edit> ... ; ./mxcli
# exec` seven times, was blocked before the edit ran, and debugged an edit that was never applied.
steps_before_exec() {
  printf '%s' "$1" | "$PY" -c 'import re, sys
text = sys.stdin.read()
m = re.search(r"(?:^|[\s;&|(])(?:\./)?mxcli(?:\.exe)?\s+exec\b", text)
if not m:
    sys.exit(0)
trivial = re.compile(r"""^((export\s+)?[A-Za-z_]\w*=("[^"]*"|\x27[^\x27]*\x27|\S*)\s*)*$|^cd\s+\S+$""")
for step in re.split(r"&&|\|\||[;|\n]", text[:m.start()]):
    if not trivial.match(step.strip()):
        print("Nothing in this command ran, the steps before the exec included (an edit there never happened): the script was checked as it is on disk. Run those steps on their own, then the exec as its own command.")
        break' 2>/dev/null
}

inline=()
case "$command" in *mxcli*-c*)
  while IFS= read -r -d '' statement; do inline+=(--inline "$statement"); done < <(inline_mdl "$command") ;;
esac
case "$command" in *"mxcli exec"*|*"mxcli.exe exec"*) ;; *) [ "${#inline[@]}" -gt 0 ] || exit 0 ;; esac
[ -f tests/precheck.sh ] || exit 0

# The .mdl words of the command, split like a shell (shlex, no execution; globs expanded,
# bounded like after-mxcli-exec.sh). Inline MDL has no script to check: let it through.
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
[ -n "$scripts" ] || [ "${#inline[@]}" -gt 0 ] || exit 0
# `for f in a b; do mxcli exec mdlsource/$f.mdl` hands the hook a literal `$f`: nothing to check.
if printf '%s\n' "$scripts" | grep -q '[$]'; then
  echo "Blocked: that exec names its script through a variable (\`$f.mdl\` in a loop), so the precheck cannot see which script runs and the model would change unchecked. Exec each script by its own path, one command per script: ./mxcli exec mdlsource/41_pages.mdl -p App.mpr" >&2
  exit 2
fi

args=()
while IFS= read -r script; do
  [ -n "$script" ] && args+=("$script")
done <<HOOK_SCRIPTS
$scripts
HOOK_SCRIPTS

out="$(bash tests/precheck.sh ${args[@]+"${args[@]}"} ${inline[@]+"${inline[@]}"} 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
  {
    echo "Blocked: that exec would break the build (mx check on a copy of the model, nothing changed). Fix the script and exec again:"
    steps_before_exec "$command"
    printf '%s\n' "$out"
  } >&2
  exit 2
fi
# Tell the model the check happened, so it does not run precheck.sh a second time by hand
# (plain stdout of a PreToolUse hook reaches the transcript only, additionalContext the model).
printf '%s\n' "$out" | head -1 | "$PY" -c 'import json,sys
line = sys.stdin.read().strip()
if line:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": line}}))' 2>/dev/null
exit 0
