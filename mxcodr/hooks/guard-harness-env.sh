#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Bash|Edit|Write|MultiEdit|NotebookEdit); the Cursor hook and
# the OpenCode and Pi plugins pass their calls through it in the same JSON shape.
#
# tests/harness.env holds the gate's switches, and it belongs to the person, not the session.
# A session building an app with no users wrote MDL_REQUIRE_PRODUCTION=0 into it; the switch
# stayed, and the next session -- asked for per-customer logins -- got DONE with security Off.
# Blocked (exit 2, the reason on stderr reaches the model):
#   - a file tool whose path is tests/harness.env (either slash, any case);
#   - a shell command that names harness.env and writes: >, >>, tee, sed -i, perl -i, cp, mv,
#     rm, truncate, dd, install, ln;
#   - tests/gate.sh or tests/precheck.sh run with a gate switch set inline
#     (MDL_REQUIRE_PRODUCTION=0 bash tests/gate.sh weakens the gate without touching the file).
# Everything else passes (exit 0): reading the file, tests/credentials.env, FRESH_SESSION,
# APP_PORT, KEEP_SESSION.

input="$(cat)"
case "$input" in *harness.env*|*tests/gate.sh*|*tests/precheck.sh*|*tests\\\\gate.sh*) ;; *) exit 0 ;; esac

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
[ -n "$PY" ] || exit 0

reason="$(printf '%s' "$input" | "$PY" -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = str(data.get("tool_name") or "")
args = data.get("tool_input") or {}
SWITCHES = ("MDL_REQUIRE_PRODUCTION", "MDL_ALLOW_GREEN_FIRST", "MDL_VISUAL", "MDL_VISUAL_REVIEW",
            "MDL_RUNTIME_ERRORS", "MDL_PRECHECK", "MDL_GATE_CACHE")
if tool.lower() == "bash":
    command = str(args.get("command") or "")
    if re.search(r"harness\.env", command) and re.search(
            r"(>>?\s*\S*harness\.env|\btee\b|\bsed\b[^|;&]*\s(-i|--in-place)|\bperl\b[^|;&]*\s-\w*i"
            r"|\b(cp|mv|rm|truncate|dd|install|ln)\b)", command):
        print("writes tests/harness.env")
    elif re.search(r"tests[/\\\\](gate|precheck)\.sh", command) and re.search(
            r"(^|[\s;&|(])(export\s+)?(%s)=" % "|".join(SWITCHES), command):
        print("sets a gate switch for this run")
elif tool.lower() in ("edit", "write", "multiedit", "notebookedit", "patch", "apply_patch"):
    path = str(args.get("file_path") or args.get("filePath") or args.get("notebook_path")
               or args.get("path") or "")
    if path.replace("\\", "/").lower().rstrip("/").endswith("tests/harness.env"):
        print("edits tests/harness.env")
' 2>/dev/null)"
[ -n "$reason" ] || exit 0

cat >&2 <<MSG
Blocked: this call $reason. tests/harness.env holds the gate's switches (MDL_REQUIRE_PRODUCTION,
MDL_ALLOW_GREEN_FIRST, MDL_VISUAL, ...) and belongs to the person, not the session: a switch a
session sets stays for every later session, whatever it is asked to build. Do not work around the
check -- meet it:
  - security: turn it on (alter project security level PRODUCTION) with a role per kind of user;
    if the app truly has no users, say so in your report and let the person decide;
  - a test never seen red: break what it checks once and watch it fail (bash tests/gate.sh --only);
  - anything else: report which check stands in the way and why, and let the person change it.
MSG
exit 2
