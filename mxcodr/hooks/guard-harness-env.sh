#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Bash|Edit|Write|MultiEdit|NotebookEdit), Codex PreToolUse on
# its shell tool; the Cursor hook and the OpenCode and Pi plugins pass their calls through it in the
# same JSON shape.
#
# The session may not change what judges it.
#   - tests/harness.env holds the gate's switches and belongs to the person. A session building an
#     app with no users wrote MDL_REQUIRE_PRODUCTION=0 into it; the next session, asked for
#     per-customer logins, got DONE with security Off.
#   - The harness's own files: tools/mdl-checks/ (checkers, hooks, lint), the harness scripts in
#     tests/ (the ones tools/mdl-checks/INSTALL.json records -- never the session's own
#     verify-*.test.sh), .claude/lint-rules/, and the hook and plugin configs that run this guard.
#     A session whose OData test failed coverage rewrote the coverage checker to get DONE.
# Blocked (exit 2, the reason on stderr reaches the model): a file tool writing one of those paths;
# a shell command that writes one (> or >> into it, tee, sed -i, perl -i, rm, truncate, dd of=, or
# cp/mv/install/ln/rsync with it as the destination); tests/gate.sh or precheck.sh run with a gate
# switch set inline. Reading, and copying FROM them, pass; so do the session's tests and scripts.
# MDL_HARNESS_EDITS=allow in tests/harness.env (the person's file) lets harness files be edited;
# harness.env itself stays the person's either way. Anything the guard cannot read passes, and the
# gate's drift check (INSTALL.json checksums) still names a changed harness file.

input="$(cat)"
case "$input" in *harness.env*|*tests/*|*tests\\\\*|*mdl-checks*|*lint-rules*|*settings.local.json*|*hooks.json*|*extensions*|*plugin*) ;; *) exit 0 ;; esac

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
import json, os, re, shlex, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = str(data.get("tool_name") or "").lower()
args = data.get("tool_input") or {}
root = os.getcwd().replace("\\", "/").rstrip("/")
ENV = "tests/harness.env"
DIRS = ["tools/mdl-checks/", "tests/gate/", "tests/lib/", ".claude/lint-rules/", ".pi/extensions/",
        ".opencode/plugin/"]
FILES = {".claude/settings.local.json", ".codex/hooks.json", ".cursor/hooks.json", "tests/gate.sh",
         "tests/lib.sh", "tests/precheck.sh", "tests/portable.sh", "tests/orient.sh",
         "tests/diagnose.sh", "tests/peek.sh", "tests/run-app.sh", "tests/run-docker.sh",
         "tests/scenario-helpers.js"}
try:
    recorded = json.load(open("tools/mdl-checks/INSTALL.json")).get("files") or {}
    FILES |= {f for f in recorded if f.startswith("tests/") and not f.startswith("tests/verify-")}
except Exception:
    pass
allow_edits = False
try:
    allow_edits = bool(re.search(r"^\s*MDL_HARNESS_EDITS\s*=\s*[\x22\x27]?allow", open(ENV).read(), re.M))
except Exception:
    pass

def rel(path):
    path = path.strip().strip("\x22\x27").replace("\\", "/")
    if path.lower().startswith(root.lower() + "/"):
        path = path[len(root) + 1:]
    while path.startswith("./"):
        path = path[2:]
    return path

def kind(path):
    p = rel(path)
    low = p.lower()
    if low == ENV or low.endswith("/" + ENV):
        return "env"
    if allow_edits:
        return None
    for f in FILES:
        if p == f or p.endswith("/" + f):
            return "harness"
    for d in DIRS:
        if p.startswith(d) or ("/" + d) in p:
            return "harness"
    return None

def shell_targets(command):
    """Paths a shell command writes: redirect targets, and the written operands of write verbs."""
    targets = []
    for segment in re.split(r"&&|\|\||[;|\n]", command):
        targets += re.findall(r">>?\s*([^\s;&|<>]+)", segment)
        try:
            words = shlex.split(segment)
        except ValueError:
            words = segment.split()
        words = [w for w in words if w not in (">", ">>")]
        if not words:
            continue
        verb = os.path.basename(words[0])
        operands = [w for w in words[1:] if not w.startswith("-")]
        if verb == "tee" or verb in ("rm", "truncate", "shred", "unlink"):
            targets += operands
        elif verb in ("sed", "perl") and any(w.startswith("-i") or w == "--in-place" for w in words[1:]):
            targets += operands
        elif verb in ("cp", "mv", "install", "ln", "rsync") and operands:
            targets.append(operands[-1])
        elif verb == "dd":
            targets += [w[3:] for w in words if w.startswith("of=")]
    return targets

SWITCHES = ("MDL_REQUIRE_PRODUCTION", "MDL_ALLOW_GREEN_FIRST", "MDL_VISUAL", "MDL_VISUAL_REVIEW",
            "MDL_RUNTIME_ERRORS", "MDL_PRECHECK", "MDL_GATE_CACHE", "MDL_HARNESS_EDITS", "MDL_CAPTIONS")
hit = None
if tool == "bash":
    command = str(args.get("command") or "")
    for target in shell_targets(command):
        k = kind(target)
        if k:
            hit = (k, rel(target))
            break
    if not hit and re.search(r"tests[/\\\\](gate|precheck)\.sh", command) and re.search(
            r"(^|[\s;&|(])(export\s+)?(%s)=" % "|".join(SWITCHES), command):
        hit = ("switch", "")
elif tool in ("edit", "write", "multiedit", "notebookedit", "patch", "apply_patch"):
    path = str(args.get("file_path") or args.get("filePath") or args.get("notebook_path")
               or args.get("path") or "")
    k = kind(path) if path else None
    if k:
        hit = (k, rel(path))
if hit:
    print("%s\t%s" % hit)
' 2>/dev/null)"
[ -n "$reason" ] || exit 0
what="${reason%%	*}"; path="${reason#*	}"

if [ "$what" = "harness" ]; then
  cat >&2 <<MSG
Blocked: this call writes $path, part of the harness that judges your work (installed by mx-codr;
the gate checks it against INSTALL.json). Do not change a check to get past it. If a check is
wrong -- it flags something that is right -- leave it, finish what you can, and say in your report
which check, what it said and why it is wrong: the person fixes it in mx-codr, for every project.
Your own tests (tests/verify-*.test.sh), scripts (mdlsource/) and tests/credentials.env are yours.
MSG
  exit 2
fi
if [ "$what" = "env" ]; then reason="writes tests/harness.env"; else reason="sets a gate switch for this run"; fi

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
