#!/usr/bin/env bash
# Sourced by the harness scripts. Nothing in here is a check or a rule -- it is the
# handful of places where the same bundle has to say something different on macOS,
# on Linux, and on Windows under Git Bash.
#
# Three differences, and only three:
#
#   * the binary is `mxcli.exe` on Windows,
#   * `python3` does not exist on Windows (and a `python3.exe` stub that opens the
#     Microsoft Store often does, which is worse than nothing),
#   * `mktemp -d -t <name>` is BSD syntax. GNU coreutils -- Linux, Git Bash and the
#     devcontainer mxcli ships -- rejects it with "too few X's in template".
#
# Callers get $MXCLI and $PY set, plus mdl_tmpdir/mdl_tmpfile. Nothing is exported:
# each script decides what to pass on.

# The project's own binary, whatever this platform calls it. An MXCLI already in
# the environment wins: a caller that named one meant it.
_mdl_base="${PORTABLE_APP_DIR:-.}"
if [ -n "${MXCLI:-}" ]; then
  :
elif [ -x "$_mdl_base/mxcli" ]; then
  MXCLI="$_mdl_base/mxcli"
elif [ -x "$_mdl_base/mxcli.exe" ]; then
  MXCLI="$_mdl_base/mxcli.exe"
else
  MXCLI="$_mdl_base/mxcli"
fi
unset _mdl_base

# Each candidate is asked to run before it is believed: the Store stub answers
# `command -v` and then does nothing useful.
#
# The off-PATH search is not paranoia. The python.org installer does not tick
# "Add python.exe to PATH" by default and winget accepts that default, so a
# Windows box can have a perfectly good Python 3.12 that no shell can see --
# observed on a clean Windows 11 VM with Python.Python.3.12 installed and
# `type -a python python3 py` empty.
mdl_find_python() {
  local candidate
  for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
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

if [ -z "${PY:-}" ]; then
  PY="$(mdl_find_python || true)"
  PY="${PY:-python3}"
fi

# How this project is built, when it is not the default. Written by install.sh,
# beside tests/credentials.env and read the same way. It records the no-Docker mode:
# which Mendix installation supplies `mx`, and which database the app runs on.
# Anything already in the environment wins, so a one-off override needs no edit.
_mdl_harness_env="$(dirname "${BASH_SOURCE[0]}")/harness.env"
if [ -f "$_mdl_harness_env" ]; then
  # shellcheck disable=SC1090
  . "$_mdl_harness_env"
fi
unset _mdl_harness_env

# A JAVA_HOME pointing at the JDK's *bin* directory rather than its home breaks
# every tool that composes "$JAVA_HOME/bin/java" -- gradle and mxbuild both do.
# Seen on a real Windows machine: JAVA_HOME=C:\Program Files (Arm)\zulu21\bin, so
# the composed path was ...\zulu21\bin\bin\java.exe. Repair it rather than leave a
# failure that surfaces minutes later as a silent hang.
if [ -n "${JAVA_HOME:-}" ]; then
  _mdl_jh="${JAVA_HOME//\\//}"
  if [ ! -x "$_mdl_jh/bin/java" ] && [ ! -x "$_mdl_jh/bin/java.exe" ]; then
    if [ -x "$_mdl_jh/java" ] || [ -x "$_mdl_jh/java.exe" ]; then
      # Strip the last path component without touching the separators: dirname on
      # "C:\Program Files\zulu21\bin" mangles a backslash path into nonsense.
      case "$JAVA_HOME" in
        *\\*) JAVA_HOME="${JAVA_HOME%\\*}" ;;
        */*)   JAVA_HOME="${JAVA_HOME%/*}" ;;
      esac
      export JAVA_HOME
    fi
  fi
  unset _mdl_jh
fi

# Studio Pro keeps the app's own data in an HSQLDB under deployment/data/database/.
# `mxbuild --target=deploy` runs a Clean up step across deployment/, and that has been
# observed leaving the database half-written: the version table's DDL is there, the row
# the runtime reads out of it is not, and the next boot dies on
# "mendixsystem$version". A killed runtime also leaves a default.lck behind, which
# blocks the boot after it. Both are visible in one grep of a text file -- no database
# needed -- so they are reported before a boot rather than after a cryptic failure.
#
# Prints nothing when the database is absent (normal, the runtime creates it), fresh,
# or healthy. Never touches anything.
mdl_check_local_database() {
  local base="${1:-${APP_DIR:-.}/deployment/data/database}"
  [ -d "$base" ] || return 0
  command -v find >/dev/null 2>&1 || return 0

  local lock
  lock="$(find "$base" -name '*.lck' -type f 2>/dev/null | head -1)"
  if [ -n "$lock" ]; then
    # A lock while the runtime is up is correct; only a leftover one is a problem.
    if ! { command -v pgrep >/dev/null 2>&1 && pgrep -f 'runtimelauncher' >/dev/null 2>&1; }; then
      echo "   !! a stale database lock is left over from a killed runtime:"
      echo "      ${lock#${APP_DIR:-.}/}"
      echo "      nothing is running now, so it only blocks the next boot:  rm '$lock'"
    fi
  fi

  local script
  script="$(find "$base" -name 'default.script' -type f 2>/dev/null | head -1)"
  [ -n "$script" ] || return 0
  grep -q 'CREATE MEMORY TABLE PUBLIC."mendixsystem\$version"' "$script" 2>/dev/null || return 0
  grep -q 'INSERT INTO "mendixsystem\$version"' "$script" 2>/dev/null && return 0
  echo "   !! the local HSQLDB is half-written: deployment/data/database holds the version"
  echo "      table but no row in it, so a boot fails on mendixsystem\$version. A deploy"
  echo "      build cleaned deployment/ underneath it. It holds demo data only -- move it"
  echo "      aside and let the runtime build a fresh one, then reseed through the app:"
  echo "      mv '$(dirname "$(dirname "$script")")' '$(dirname "$(dirname "$script")").broken-$(date +%H%M%S)'"
}

# Has the harness in this project drifted from the one that was installed? A
# project once ran checkers from 2026.09.09 against a bundle at 2026.09.11 and
# reported `naming: PASS` where the current checker finds 37 problems -- a gate
# that passes because it is out of date is worse than no gate, because the green
# is still printed. tools/mdl-checks/record_install.py writes a checksum per
# installed file into INSTALL.json; this compares the files on disk against it,
# and the version against dist/ when the project keeps a bundle. Around forty
# small checksums, roughly ten milliseconds. Silent when nothing has drifted.
mdl_check_install_freshness() {
  local app="${APP_DIR:-.}"
  local manifest="$app/tools/mdl-checks/INSTALL.json"
  local installed="$app/tools/mdl-checks/VERSION"
  local python="${PY:-$(mdl_find_python || true)}"

  [ -n "$python" ] || return 0

  if [ ! -f "$manifest" ]; then
    # Installed before manifests existed, or assembled by hand. Worth one line:
    # the check cannot run, and silence would read as a clean result.
    if [ -f "$installed" ] && [ -d "$app/dist" ]; then
      echo "   !! no tools/mdl-checks/INSTALL.json, so harness drift cannot be detected here."
      echo "      This install predates the record (VERSION says $(cat "$installed" 2>/dev/null)):  bash dist/install.sh ."
    fi
    return 0
  fi

  "$python" - "$app" "$manifest" <<'PY_FRESH'
import hashlib, json, os, sys

app, manifest_path = sys.argv[1], sys.argv[2]
try:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except Exception:
    raise SystemExit(0)

installed = manifest.get("version", "?")
changed, missing = [], []
for relative, expected in sorted((manifest.get("files") or {}).items()):
    try:
        with open(os.path.join(app, *relative.split("/")), "rb") as handle:
            actual = hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        missing.append(relative)
        continue
    if actual != expected:
        changed.append(relative)


def name_some(paths, limit):
    shown = ", ".join(paths[:limit])
    if len(paths) > limit:
        shown += " and %d more" % (len(paths) - limit)
    return shown


def ordered(version):
    # 2026.09.11.28 sorts after 2026.09.11.3, which string comparison gets wrong
    # as soon as a within-day counter passes 9 -- and they reach 28.
    try:
        return tuple(int(part) for part in version.split("."))
    except (AttributeError, ValueError):
        return ()


# A newer bundle sitting in the project is the plainest signal there is. The
# other direction is the hand-copy case, where the files are ahead of dist/ on
# purpose, so it is left alone -- the checksums below cover it.
bundle = os.path.join(app, "dist", "VERSION")
if os.path.exists(bundle):
    try:
        with open(bundle, encoding="utf-8") as handle:
            available = handle.read().strip()
    except OSError:
        available = ""
    if available and ordered(available) > ordered(installed):
        print("   !! the harness installed here is %s; dist/ holds a newer one (%s)."
              % (installed, available))
        print("      An out-of-date checker passes what the current one fails:  bash dist/install.sh .")

if missing:
    print("   !! %d harness file(s) gone since install: %s"
          % (len(missing), name_some(missing, 3)))
    print("      re-run the installer to put them back")

if changed:
    print("   !! differs from the installed harness (%s): %s"
          % (installed, name_some(changed, 4)))
    print("      either these were edited here, and the next install overwrites them -- send a")
    print("      real fix upstream -- or newer files were copied in and the VERSION stamp is stale")
PY_FRESH
}

mdl_tmpdir() {  # mdl_tmpdir <name> -- portable `mktemp -d -t <name>`
  mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"
}

mdl_tmpfile() {  # mdl_tmpfile <name> -- portable `mktemp -t <name>`
  mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}
