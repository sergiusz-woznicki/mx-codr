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
# beside tests/credentials.env and read the same way: as DATA, never sourced.
#
# It used to be sourced, and that was the bundle's widest hole. The file lives in the
# project tree, so a clone or an agent could put shell in it and every gate run, every
# orient, and every verify-*.test.sh -- lib.sh loads this file too -- would execute it
# before a single check ran. Sourcing also let it set *any* variable, so a line like
# BASE_URL=https://elsewhere pointed the whole suite, credentials and all, at another
# host. Parsing KEY=value against the list below closes both.
#
# A value is taken literally: no expansion, no command substitution, one layer of
# quotes stripped because that is the shape install.sh writes. The file wins over the
# environment for these keys, which is what sourcing did.
#
# mdl_load_harness_env <file> [export]
mdl_load_harness_env() {
  local file="$1" mode="${2:-}" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    [ "$key" != "$line" ] || continue          # no '=' on the line
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"       # trim surrounding blanks
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in
      MDL_NO_DOCKER|MDL_MXBUILD_PATH|MDL_DB_HOST|MDL_DB_NAME|MDL_DB_USER|MDL_DB_PASSWORD| \
      MDL_PSQL|MDL_BOOT_COMMAND|JAVA_HOME|MX_VERSION) ;;
      *) continue ;;
    esac
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf -v "$key" '%s' "$value"
    if [ "$mode" = "export" ]; then export "${key?}"; fi
  done < "$file"
  # Every caller sources this under `set -e` (lib.sh, run-app.sh). A loop whose last
  # test came out false made this function return 1, and that ended every browser
  # test silently in 17ms whenever a harness.env existed -- the no-Docker mode.
  return 0
}

_mdl_harness_env="$(dirname "${BASH_SOURCE[0]}")/harness.env"
mdl_load_harness_env "$_mdl_harness_env"
unset _mdl_harness_env

# --- values that have to survive a trip into generated code ------------------
#
# lib.sh builds a JavaScript body and gate.sh builds SQL; a password or a project
# name written straight into either one is a quote away from being code. These three
# hand the encoding to Python, which is on every machine the harness runs on.

mdl_json_object() {   # mdl_json_object k1 v1 k2 v2 ... -> {"k1":"v1",...}
  "$PY" -c 'import json,sys
a = sys.argv[1:]
print(json.dumps(dict(zip(a[0::2], a[1::2])), ensure_ascii=True))' "$@"
}

mdl_json_string() {   # mdl_json_string <text> -> "text", escaped for JS source
  "$PY" -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=True))' "$1"
}

mdl_ere_quote() {     # mdl_ere_quote <text> -- match it literally inside an ERE
  printf '%s' "$1" | sed 's/[][^$.*+?(){}|\\\\]/\\\\&/g'
}

mdl_json_number() {   # mdl_json_number <value> <fallback> -- digits only, never code
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *)           printf '%s\n' "$1" ;;
  esac
}

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
# and the version against mxcodr/ when the project keeps a bundle. Around forty
# small checksums, roughly ten milliseconds. Silent when nothing has drifted.
mdl_check_install_freshness() {
  local app="${APP_DIR:-.}"
  local manifest="$app/tools/mdl-checks/INSTALL.json"
  local installed="$app/tools/mdl-checks/VERSION"
  local python="${PY:-$(mdl_find_python || true)}"
  # The bundle a project keeps beside itself is mxcodr; a copy made before the
  # rename on 2026-09-15 still calls it dist.
  local bundle="" candidate
  for candidate in mxcodr dist; do
    if [ -f "$app/$candidate/VERSION" ]; then bundle="$candidate"; break; fi
  done

  [ -n "$python" ] || return 0

  if [ ! -f "$manifest" ]; then
    # Installed before manifests existed, or assembled by hand. Worth one line:
    # the check cannot run, and silence would read as a clean result.
    if [ -f "$installed" ] && [ -n "$bundle" ]; then
      echo "   !! no tools/mdl-checks/INSTALL.json, so harness drift cannot be detected here."
      # Installing from a bundle older than what is already here would be a
      # downgrade, so say which of the two has to move first.
      if [ "$(printf '%s\n%s\n' "$(cat "$installed")" "$(cat "$app/$bundle/VERSION")" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)" = "$(cat "$installed")" ] \
         && [ "$(cat "$installed")" != "$(cat "$app/$bundle/VERSION")" ]; then
        echo "      $bundle/ is older than what is installed ($(cat "$app/$bundle/VERSION") vs $(cat "$installed")); refresh $bundle/ first, then:  bash $bundle/install.sh ."
      else
        echo "      This install predates the record (VERSION says $(cat "$installed" 2>/dev/null)):  bash $bundle/install.sh ."
      fi
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
# other direction is the hand-copy case, where the files are ahead of mxcodr/ on
# purpose, so it is left alone -- the checksums below cover it.
# mxcodr beside the project, or dist in a copy made before the 2026-09-15 rename.
name = next((n for n in ("mxcodr", "dist") if os.path.exists(os.path.join(app, n, "VERSION"))), None)
bundle = os.path.join(app, name, "VERSION") if name else ""
if bundle:
    try:
        with open(bundle, encoding="utf-8") as handle:
            available = handle.read().strip()
    except OSError:
        available = ""
    if available and ordered(available) > ordered(installed):
        print("   !! the harness installed here is %s; %s/ holds a newer one (%s)."
              % (installed, name, available))
        print("      An out-of-date checker passes what the current one fails:  bash %s/install.sh ." % name)

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
