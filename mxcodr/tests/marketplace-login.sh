#!/usr/bin/env bash
# tests/marketplace-login.sh -- a Marketplace module the app needs, and a person who has to log in.
#
#   bash tests/marketplace-login.sh status            one line for orient.sh: logged in or not
#   bash tests/marketplace-login.sh needs <file>      build output (mx check) naming a missing module:
#                                                     the login message (exit 3), or how to install it
#   bash tests/marketplace-login.sh probe <file>      the same output from a precheck run by hand: says
#                                                     what an exec would need, never sets the wait flag
#   bash tests/marketplace-login.sh before <command>  a tool call about to run: exit 3 and the login
#                                                     message while a login is pending
#
# A DeepSeek session needed three Marketplace modules (BusinessEvents, External Database Connector,
# the GenAI stack). `mxcli marketplace` answered "no credential found. Run: mxcli auth login" -- a
# login only the person can do -- and the session built a Java imitation of each feature instead,
# which passed the gate. Now the first missing module stops the work with a short instruction, and
# every build, gate or Marketplace call is refused until mxcli is logged in; then it lets go by
# itself. MDL_MARKETPLACE_LOGIN=report (tests/harness.env) is for unattended runs (`pi -p`), where
# nobody can log in: nothing is blocked, and the model reports the feature as not built.
#
# The token is never read here: mxcli keeps it in ~/.mxcli/auth.json (or MENDIX_PAT), and
# `mxcli auth status --offline` only says whether one is there.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 0
# shellcheck source=portable.sh
. tests/portable.sh

FLAG=.mxcli/marketplace-login-needed
MODE="${MDL_MARKETPLACE_LOGIN:-wait}"

logged_in() { "$MXCLI" auth status --offline >/dev/null 2>&1; }

# The module a build error names: "We couldn't find the External Database Connector module in your app".
missing_module() { grep -oE "couldn.t find the [^.\"]+ module in your app" "$1" 2>/dev/null | head -1 | sed -E "s/couldn.t find the (.*) module in your app/\1/"; }

login_message() {   # login_message <what needs it>
  cat <<EOF
Blocked: this app needs $1 from the Mendix Marketplace, and mxcli is not logged in to it.
STOP HERE and ask the person to log in once, in their own terminal -- never paste the token into this chat:
  1. create a token: https://user-settings.mendix.com -> Developer Settings -> Personal Access Tokens
  2. cd "$(pwd)" && ./mxcli auth login      (paste the token when it asks)
Do not continue, and do not build a replacement for the feature, until they say it is done. Once mxcli
is logged in, the harness lets every command through again by itself.
If the person does not want that module, they can set MDL_MARKETPLACE_LOGIN=report in tests/harness.env
(and delete .mxcli/marketplace-login-needed): nothing waits, and the feature is reported as not built.
EOF
}

report_message() {   # report_message <what needs it>
  echo "   $1 comes from the Mendix Marketplace and mxcli is not logged in (MDL_MARKETPLACE_LOGIN=report: nobody can log in during this run). Do not build a replacement: leave the feature out and name it in your report as not built, needing that module and \`./mxcli auth login\`."
}

case "${1:-}" in
  status)
    if logged_in; then
      echo "Marketplace: logged in -- a missing module can be installed (skill: download-marketplace-content)"
    else
      echo "Marketplace: not logged in -- a feature that needs a module (Business Events, External Database Connector, GenAI) cannot be installed until the person runs ./mxcli auth login"
    fi ;;

  needs)
    module="$(missing_module "${2:-}")"
    [ -n "$module" ] || exit 0
    if logged_in; then
      rm -f "$FLAG"
      echo "   hint: $module is a Marketplace module -- install it, then exec again: ./mxcli marketplace search \"$module\" (gives its content id), ./mxcli marketplace install <id> -p <app>.mpr. Skill: download-marketplace-content"
      exit 0
    fi
    if [ "$MODE" = "report" ]; then
      report_message "$module"
      exit 0
    fi
    mkdir -p .mxcli 2>/dev/null && printf '%s\n' "$module" > "$FLAG"
    login_message "the $module module"
    exit 3 ;;

  probe)
    module="$(missing_module "${2:-}")"
    [ -n "$module" ] || exit 0
    if logged_in; then
      echo "   hint: $module is a Marketplace module -- an exec would install it: ./mxcli marketplace search \"$module\", ./mxcli marketplace install <id> -p <app>.mpr. Skill: download-marketplace-content"
    elif [ "$MODE" = "report" ]; then
      report_message "$module"
    else
      echo "   note: $module comes from the Mendix Marketplace and mxcli is not logged in. This precheck run by hand does not stop the work, but an exec of a script that needs it would: it then waits for the person's ./mxcli auth login. If the feature cannot be built without the module, ask the person before you exec."
    fi
    exit 0 ;;

  before)
    command="${2:-}"
    [ "$MODE" = "report" ] && exit 0
    # Only a call that builds, RUNS the gate or reaches the Marketplace waits for the login. Reading
    # tests/gate.sh (grep, cat, sed) is not running it: a session was refused a grep of it.
    if ! printf '%s' "$command" | grep -qE 'mxcli(\.exe)? (exec|marketplace|catalog)([[:space:]]|$)|(^|[;&|(]|[[:space:]])(bash|sh)[[:space:]]+(\./)?tests/gate\.sh|(^|[;&|(]|[[:space:]])\./tests/gate\.sh'; then
      exit 0
    fi
    case "$command" in *"mxcli auth"*|*"mxcli.exe auth"*) exit 0 ;; esac
    # Reading the help needs no login: `mxcli marketplace --help` was refused.
    if printf '%s' "$command" | grep -qE 'mxcli(\.exe)? (marketplace|catalog)[^;&|]*(--help|-h)([[:space:]]|$)|mxcli(\.exe)? help (marketplace|catalog)'; then
      exit 0
    fi
    pending=""
    [ -f "$FLAG" ] && pending="$(head -1 "$FLAG")"
    case "$command" in *"mxcli marketplace"*|*"mxcli.exe marketplace"*|*"mxcli catalog"*|*"mxcli.exe catalog"*) pending="${pending:-a module}" ;; esac
    [ -n "$pending" ] || exit 0
    if logged_in; then
      rm -f "$FLAG"
      exit 0
    fi
    # A Marketplace call alone is refused but does not set the flag: only a build that names a
    # missing module holds every later build back.
    case "$pending" in "a module") login_message "a module" ;; *) login_message "the $pending module" ;; esac
    exit 3 ;;

  *)
    echo "usage: bash tests/marketplace-login.sh status | needs <file> | probe <file> | before <command>" >&2
    exit 2 ;;
esac
