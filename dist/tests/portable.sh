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

mdl_tmpdir() {  # mdl_tmpdir <name> -- portable `mktemp -d -t <name>`
  mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"
}

mdl_tmpfile() {  # mdl_tmpfile <name> -- portable `mktemp -t <name>`
  mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}
