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
#
# Searching or reading outside the project is blocked too: a session ran `find / -name login.js`
# (a whole-disk scan, killed after minutes) and read the mxcli source checkout under /private/tmp
# for a widget's syntax. Nothing outside the project answers a Mendix question. Blocked: find,
# recursive grep, rg/ag/fd, mdfind and locate rooted outside the project; cat/sed/head/tail/less/
# strings/awk of a file under /System, /Applications, /Library, /usr, /opt, ~/.mxcli/mxbuild|runtime,
# or inside a source checkout under /tmp (a directory with .git, go.mod or package.json above the
# file). The session's own scratch files under /tmp pass, and so does a redirect INTO /tmp: a
# DeepSeek run's `cat > /tmp/mdlprobe/x.mdl <<EOF` was blocked as a read on the first day.

input="$(cat)"
case "$input" in *harness.env*|*tests/*|*tests\\\\*|*mdl-checks*|*lint-rules*|*settings.local.json*|*hooks.json*|*extensions*|*plugin*) ;;
  *find\ *|*grep\ *|*egrep\ *|*fgrep\ *|*rg\ *|*ag\ *|*fd\ *|*mdfind*|*locate\ *|*/System/*|*/Applications/*|*/Library/*|*/usr/*|*/opt/*|*/private/*|*/tmp/*|*~/*|*\$HOME*|*/Users/*|*/home/*) ;;
  # The Mendix token: auth.json, $MENDIX_PAT, or a dump of the environment that holds it.
  *auth.json*|*MENDIX_PAT*|*env*|*set*|*export*|*declare*|*marketplace-login-needed*) ;;
  *) exit 0 ;; esac

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
if [ -z "$PY" ]; then
  # Without Python nothing below can read the call. Everything passes except a call that names
  # harness.env, the file whose values the harness runs: that one is not waved through unread.
  case "$input" in
    *harness.env*)
      echo "Blocked: this call names tests/harness.env and the guard cannot read it (no working Python found). tests/harness.env belongs to the person; ask them to make the change." >&2
      exit 2 ;;
  esac
  exit 0
fi

# The decision is checks/guard_harness.py, installed one directory up from this hook (in the
# bundle: beside it, under checks/). Without it nothing here can read the call: the same answer
# as without Python.
guard_py=""
for candidate in "$(dirname "$0")/../guard_harness.py" "$(dirname "$0")/../checks/guard_harness.py"; do
  [ -f "$candidate" ] && { guard_py="$candidate"; break; }
done
if [ -z "$guard_py" ]; then
  case "$input" in
    *harness.env*)
      echo "Blocked: this call names tests/harness.env and the guard cannot read it (tools/mdl-checks/guard_harness.py is missing; re-run the installer). tests/harness.env belongs to the person." >&2
      exit 2 ;;
  esac
  exit 0
fi
reason="$(printf '%s' "$input" | "$PY" "$guard_py" 2>/dev/null)"
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
if [ "$what" = "token" ]; then
  cat >&2 <<MSG
Blocked: that would show the Mendix token ($path). mxcli reads it by itself for every
./mxcli marketplace call -- you never need its value, and whatever a command prints ends up in this
session's log. To see whether mxcli is logged in: ./mxcli auth status --offline (it shows no token).
MSG
  exit 2
fi
if [ "$what" = "outside" ]; then
  cat >&2 <<MSG
Blocked: that searches or reads outside this project ($path). Nothing outside the project answers
a Mendix question, and a whole-disk scan runs for minutes: the model is read with ./mxcli (SHOW,
DESCRIBE), syntax with ./mxcli syntax <topic> (the digest in your context lists the topics), widgets
in .ai-context/skills/widgets/, and what a check wants in tests/checks/<step>.md (index: tests/CHECKS.md). Users sign in on the
runtime's own page: security PRODUCTION and demo users, no login code of your own. Studio Pro,
mxbuild and the mxcli source hold nothing you need.
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
