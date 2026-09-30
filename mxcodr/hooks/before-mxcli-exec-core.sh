#!/usr/bin/env bash
# hooks/before-mxcli-exec-core.sh -- the part of the before-exec hook every host shares. Sourced by
# before-mxcli-exec.sh (Claude Code, Codex) and before-mxcli-exec-cursor.sh (Cursor); never run on
# its own. The two hooks differed only in how they read the call and answer it, and three changes
# in one day were made twice each. Provides: PY, hook_sleep_message, inline_mdl,
# steps_before_exec, hook_scripts, script_written_before_exec, hook_marketplace_wait, HOOK_VARIABLE_MESSAGE, HOOK_BLOCKED_HEAD, hook_precheck.

# Prints the first Python that actually runs (Windows may have only a Store stub).
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

# hook_sleep_message <command> -- prints the block message when the command sleeps before the gate
# or a log wait (`...; sleep 12; bash tests/gate.sh`): the gate waits for the runtime itself.
hook_sleep_message() {
  if printf '%s' "$1" | grep -qE '(^|[^[:alnum:]_])sleep[[:space:]]+[0-9]' \
     && printf '%s' "$1" | grep -qE 'tests/gate\.sh|gate-boot\.log|runtime\.log'; then
    echo "Blocked: drop the \`sleep\` -- tests/gate.sh waits for the runtime and for --watch to apply the latest change itself, and says so; a hand-rolled wait only adds seconds. Run the same command without it."
  fi
}

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

# hook_scripts <command> -- the .mdl words of the command, one per line, split like a shell (shlex,
# no execution; globs expanded, bounded like after-mxcli-exec.sh).
hook_scripts() {
  printf '%s' "$1" | "$PY" -c 'import glob, os, shlex, sys
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
    # `$PWD/mdlsource/x.mdl` is the project itself, not a loop variable.
    for var in ("${PWD}/", "$PWD/", "$(pwd)/"):
        if word.startswith(var):
            word = os.getcwd() + "/" + word[len(var):]
    seen.add(word)
    matches = []
    if any(c in word for c in "*?[") and word.count("*") <= 4:
        for i, match in enumerate(sorted(glob.iglob(word))):
            if i >= LIMIT:
                matches = []
                break
            matches.append(match)
    print("\n".join(matches) if matches else word)' 2>/dev/null
}

# script_written_before_exec <command> <script>... -- prints the block message when a step before
# the exec writes one of its scripts (an edit, a move, a new file). The precheck runs before the
# command, so it checked the old file -- or found none and let the exec through: a DeepSeek session
# ran `mv 05b.mdl 04c.mdl && mxcli exec 04c.mdl`, and a python edit followed by the exec put four
# build errors into the model. A step that only reads the script (grep, cat) is fine. Same rule as
# scriptWrittenBeforeExec in checks/plugins/harness-core.cjs.
script_written_before_exec() {
  local command="$1"; shift
  printf '%s' "$command" | "$PY" -c 'import re, sys
text = sys.stdin.read()
m = re.search(r"(?:^|[\s;&|(])(?:\./)?mxcli(?:\.exe)?\s+exec\b", text)
if not m:
    sys.exit(0)
before = text[:m.start()]
writes = re.search(r"<<|(^|[\s;&|(])(mv|cp|tee|rm|ln|rsync|install|patch|ed|perl|python3?|node|ruby|git)\s|(^|[\s;&|(])sed\s+(-[a-zA-Z]*\s+)*-i", before)
for script in sys.argv[1:]:
    name = script.rsplit("/", 1)[-1]
    redirected = re.search(r">>?\s*\S*" + re.escape(name), before)
    if redirected or (writes and (script in before or name in before)):
        print("Blocked: a step before the exec writes %s (an edit, a move or a new file), and the precheck runs before the command -- it would check the old file, or none. Nothing in this command ran. Run that step on its own, then `./mxcli exec %s` as its own command." % (script, script))
        break' "$@" 2>/dev/null
}

# hook_marketplace_wait <command> -- prints the login message, and returns 3, while the app needs a
# Marketplace module and mxcli is not logged in (tests/marketplace-login.sh decides); 0 otherwise.
hook_marketplace_wait() {
  [ -f tests/marketplace-login.sh ] || return 0
  HOOK_MARKETPLACE_OUT="$(bash tests/marketplace-login.sh before "$1" 2>/dev/null)"
}

HOOK_VARIABLE_MESSAGE="Blocked: that exec names its script through a variable (\`\$f.mdl\` in a loop), so the precheck cannot see which script runs and the model would change unchecked. Exec each script by its own path, one command per script: ./mxcli exec mdlsource/41_pages.mdl -p App.mpr"
HOOK_BLOCKED_HEAD="Blocked: that exec would break the build (mx check on a copy of the model, nothing changed). Fix the script and exec again:"

# hook_precheck <script>... [--inline <mdl>]... -- runs tests/precheck.sh; HOOK_OUT holds its output,
# HOOK_STATUS its exit code.
hook_precheck() {
  HOOK_OUT="$(bash tests/precheck.sh "$@" 2>&1)"
  HOOK_STATUS=$?
}
