#!/usr/bin/env bash
# Install the MDL skills, lint rules and checkers into a Mendix project.
#
#   bash install.sh [path-to-project] [--no-app]
#
# With no path it installs into the current directory -- and running it from
# inside the bundle installs into the project the bundle sits in, because that
# is what someone means who has just copied dist/ into their app and cd'd there.
#
# What lands where, and why each copy is needed:
#
#   .claude/skills/<name>/       Claude Code reads this
#   .agents/skills/<name>/       Codex, and other tools on the open SKILL.md standard
#   .ai-context/skills/<name>/   mxcli, Cursor, OpenCode, Windsurf, Aider, Vibe
#   .claude/lint-rules/          picked up by `mxcli lint`
#   tools/mdl-checks/            the Python checkers, at one path every host can cite
#
# The three skill directories hold identical files. They are copies rather than
# symlinks so a teammate who clones only the app still gets them.
#
# Nothing here edits .claude/settings.json or AGENTS.md. Those belong to mxcli.
# Host-specific hook registrations are merged into the durable local files that
# mxcli leaves alone: .claude/settings.local.json and .codex/hooks.json.
set -euo pipefail

# ---------------------------------------------------------------------------
# Platform. The bundle runs on macOS, Linux, and on Windows under Git Bash --
# where the binary is mxcli.exe, `python3` does not exist, and a `python3.exe`
# stub that opens the Microsoft Store often does. Each interpreter candidate is
# asked to run before it is believed.
# ---------------------------------------------------------------------------
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1; EXE=".exe" ;;
  *)                    IS_WINDOWS=0; EXE="" ;;
esac

mdl_find_python() {
  local candidate
  for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  # The python.org installer leaves "Add python.exe to PATH" unticked by default
  # and winget accepts that default, so a Windows box can hold a working Python
  # that no shell can see. Observed on a clean Windows 11 VM.
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
# Deliberately not fatal here: with --with-deps the prerequisites step installs
# Python and re-probes. It is that step, not this one, that gives up.

# ---------------------------------------------------------------------------
# Presentation. Everything below is output only -- no install step depends on
# it. Three environments have to read the same run: an interactive terminal
# (colour, one live progress bar), a pipe or CI log (plain lines, no escape
# codes, no carriage returns), and a terminal without UTF-8 (ASCII icons).
# NO_COLOR is honoured; so is TERM=dumb.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  UI_TTY=1
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[38;5;39m'; C_CYAN=$'\033[38;5;44m'; C_GREEN=$'\033[38;5;42m'
  C_YELLOW=$'\033[38;5;214m'; C_RED=$'\033[38;5;203m'; C_GREY=$'\033[38;5;245m'
else
  UI_TTY=0
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*) UI_UNICODE=1 ;;
  *) UI_UNICODE=0 ;;
esac

if [ "$UI_UNICODE" = 1 ]; then
  I_OK="✔"; I_WARN="!"; I_FAIL="✘"; I_DOT="·"; I_ARROW="→"; I_PLAY="▶"; I_BOX="▪"
  BAR_FULL="█"; BAR_EMPTY="░"
else
  I_OK="+"; I_WARN="!"; I_FAIL="x"; I_DOT="-"; I_ARROW="->"; I_PLAY=">"; I_BOX="*"
  BAR_FULL="#"; BAR_EMPTY="."
fi

ui_banner() {
  local version="$1"
  # The wordmark is 74 columns with its indent; below that it would wrap and the
  # first thing the installer does is look broken. Narrow terminals get the words.
  if [ "$UI_UNICODE" = 1 ] && [ "${UI_COLS:-80}" -ge 76 ]; then
    printf '\n'
    printf '%s  ███╗   ███╗███████╗███╗   ██╗██████╗ ███████╗██╗██╗  ██╗███████╗██████╗ %s\n' "$C_BLUE" "$C_RESET"
    printf '%s  ████╗ ████║██╔════╝████╗  ██║██╔══██╗██╔════╝██║╚██╗██╔╝██╔════╝██╔══██╗%s\n' "$C_BLUE" "$C_RESET"
    printf '%s  ██╔████╔██║█████╗  ██╔██╗ ██║██║  ██║█████╗  ██║ ╚███╔╝ █████╗  ██████╔╝%s\n' "$C_CYAN" "$C_RESET"
    printf '%s  ██║╚██╔╝██║██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██║ ██╔██╗ ██╔══╝  ██╔══██╗%s\n' "$C_CYAN" "$C_RESET"
    printf '%s  ██║ ╚═╝ ██║███████╗██║ ╚████║██████╔╝██║     ██║██╔╝ ██╗███████╗██║  ██║%s\n' "$C_CYAN" "$C_RESET"
    printf '%s  ╚═╝     ╚═╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝%s\n' "$C_CYAN" "$C_RESET"
    printf '\n%s  m x c l i%s   %s%s  %s%s\n\n' \
      "$C_BOLD" "$C_RESET" "$C_GREY" "$I_DOT" "$version" "$C_RESET"
  else
    printf '\n  %smendfixer%s  %s\n' "$C_BOLD" "$C_RESET" "$version"
    printf '  mxcli %s MDL skills, lint rules, hooks and the delivery gate\n\n' "$I_DOT"
  fi
}

# Progress is counted in whole install steps, and the count is fixed before the
# first one runs -- a bar that reaches 90%% and then discovers more work is a
# lie. The long step (creating a Mendix app) reports mxcli's own phase names as
# sub-progress inside its own share of the bar, never beyond it.
UI_COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
[ "$UI_COLS" -ge 40 ] 2>/dev/null || UI_COLS=80
UI_TOTAL=1
UI_STEP=0
UI_LABEL=""
UI_SUB_SEEN=0
UI_SUB_EXPECTED=6

ui_plan() { UI_TOTAL="$1"; }

ui_pct() {
  local span=$(( 100 / UI_TOTAL ))
  local base=$(( UI_STEP * 100 / UI_TOTAL ))
  local inside=0
  if [ "$UI_SUB_SEEN" -gt 0 ]; then
    inside=$(( span * UI_SUB_SEEN / UI_SUB_EXPECTED ))
    [ "$inside" -gt $(( span * 9 / 10 )) ] && inside=$(( span * 9 / 10 ))
  fi
  echo $(( base + inside ))
}

ui_bar() {
  [ "$UI_TTY" = 1 ] || return 0
  local pct width filled i bar=""
  pct="$(ui_pct)"
  width=24
  filled=$(( pct * width / 100 ))
  i=0
  while [ "$i" -lt "$width" ]; do
    if [ "$i" -lt "$filled" ]; then bar="$bar$BAR_FULL"; else bar="$bar$BAR_EMPTY"; fi
    i=$(( i + 1 ))
  done
  # 2 indent + bar + 2 + 4 pct + 2 = width + 10; leave a column spare.
  local label="$UI_LABEL" max=$(( UI_COLS - width - 11 ))
  [ "$max" -lt 8 ] && max=8
  if [ "${#label}" -gt "$max" ]; then label="${label:0:$(( max - 1 ))}~"; fi
  printf '\r\033[K  %s%s%s  %s%3s%%%s  %s%s%s' \
    "$C_BLUE" "$bar" "$C_RESET" "$C_BOLD" "$pct" "$C_RESET" "$C_GREY" "$label" "$C_RESET"
}

ui_clear() { [ "$UI_TTY" = 1 ] && printf '\r\033[K'; return 0; }

ui_begin() {           # ui_begin "label"
  UI_LABEL="$1"
  UI_SUB_SEEN=0
  [ "$UI_TTY" = 1 ] || printf '  %s %s\n' "$I_DOT" "$1"
  ui_bar
}

ui_sub() {             # ui_sub "phase name" -- transient detail inside a step
  UI_SUB_SEEN=$(( UI_SUB_SEEN + 1 ))
  if [ "$UI_TTY" = 1 ]; then
    UI_LABEL="${UI_LABEL%% $I_DOT *} $I_DOT $1"
    ui_bar
  else
    printf '     %s %s\n' "$I_DOT" "$1"
  fi
}

ui_tick() {            # progress without a new label: the tool is still working
  UI_SUB_SEEN=$(( UI_SUB_SEEN + 1 ))
  ui_bar
}

ui_done() {            # ui_done "label" "detail"
  UI_STEP=$(( UI_STEP + 1 ))
  UI_SUB_SEEN=0
  ui_clear
  if [ -n "${2:-}" ]; then
    printf '  %s%s%s %-26s %s%s%s\n' "$C_GREEN" "$I_OK" "$C_RESET" "$1" "$C_GREY" "$2" "$C_RESET"
  else
    printf '  %s%s%s %s\n' "$C_GREEN" "$I_OK" "$C_RESET" "$1"
  fi
  UI_LABEL=""
  ui_bar
}

ui_note() {            # a fact worth keeping on screen, not a step
  ui_clear
  printf '  %s%s%s %s\n' "$C_YELLOW" "$I_WARN" "$C_RESET" "$1"
  ui_bar
}

ui_fail() {            # print every argument as its own line, then die
  ui_clear
  printf '  %s%s%s %s%s%s\n' "$C_RED" "$I_FAIL" "$C_RESET" "$C_BOLD" "$1" "$C_RESET" >&2
  shift
  while [ "$#" -gt 0 ]; do printf '    %s\n' "$1" >&2; shift; done
  printf '\n' >&2
  exit 1
}

ui_head() {            # section heading in the summary
  printf '\n  %s%s %s%s\n' "$C_BOLD" "$1" "$2" "$C_RESET"
}

ui_row() {             # ui_row "what" "count" "where" -- summary line
  printf '     %s%-10s%s %s%3s%s  %s\n' "$C_CYAN" "$1" "$C_RESET" "$C_BOLD" "$2" "$C_RESET" "$3"
}

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(cat "$SRC/VERSION")"

# ---------------------------------------------------------------------------
# Prerequisites. The harness needs six tools beyond bash, and a user who is
# missing one has always found out much later -- when the suite failed, not when
# they installed. These helpers detect each, and with --with-deps install it
# through whatever package manager this machine has.
#
# Two are deliberately never installed, only reported: Docker Desktop and the
# JDK. Both need a reboot, a daemon or a licence click, so a script that
# "finished" without them would have lied about being done.
#
# MDL_DEPS_DRY_RUN=1 prints each command instead of running it -- the only way
# to exercise the winget branch from a Mac, and how this was tested.
# ---------------------------------------------------------------------------
DEPS_INSTALLED=0
DEPS_MISSING=()          # human lines, printed in the summary rather than mid-step

have() { command -v "$1" >/dev/null 2>&1; }

pkg_manager() {
  if [ "$IS_WINDOWS" = "1" ]; then have winget && { echo winget; return 0; }; fi
  have brew   && { echo brew;   return 0; }
  have apt-get && { echo apt;   return 0; }
  have dnf    && { echo dnf;    return 0; }
  echo ""
}

# Root in a container has no sudo; a normal user outside one needs it.
SUDO=""
if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && have sudo; then SUDO="sudo "; fi

dep_run() {              # dep_run "<shell command>" -- honours the dry run
  if [ -n "${MDL_DEPS_DRY_RUN:-}" ]; then
    ui_note "would run: $1"
    return 0
  fi
  eval "$1" >>"$DEPS_LOG" 2>&1
}

# dep_apply <label> <detect-command> <install-command>
#
# Returns 0 when the tool is there afterwards. Never aborts the install: a
# missing Node must not stop the skills from landing.
dep_apply() {
  local label="$1" detect="$2" command="$3"
  eval "$detect" >/dev/null 2>&1 && return 0

  if [ "$WITH_DEPS" = "0" ] || [ -z "$command" ]; then
    DEPS_MISSING+=("$label -- ${command:-no package manager found; install it by hand}")
    return 1
  fi

  ui_sub "installing $label"
  if dep_run "$command" && { [ -n "${MDL_DEPS_DRY_RUN:-}" ] || eval "$detect" >/dev/null 2>&1; }; then
    DEPS_INSTALLED=$(( DEPS_INSTALLED + 1 ))
    return 0
  fi
  DEPS_MISSING+=("$label -- $command  (tried, and it did not take; see $DEPS_LOG)")
  return 1
}

# dep_need <label> <detect> <winget-id> <brew-formula> <apt-package>
dep_need() {
  local command=""
  case "$(pkg_manager)" in
    winget) command="winget install -e --accept-package-agreements --accept-source-agreements --id $3" ;;
    brew)   command="brew install $4" ;;
    apt)    command="${SUDO}apt-get update -qq && ${SUDO}apt-get install -y $5" ;;
    dnf)    command="${SUDO}dnf install -y $5" ;;
  esac
  dep_apply "$1" "$2" "$command"
}

# Always time-boxed. `docker info` does not fail when the daemon is merely starting
# -- it blocks, forever, and Docker Desktop takes a minute or two to come up after a
# first install. Measured on Windows 11: still hanging at 20s with the whale
# spinning. An unbounded probe here froze the whole installer at 0%.
docker_ready() {
  have docker || return 1
  if have timeout; then
    timeout "${DOCKER_PROBE_TIMEOUT:-8}" docker info >/dev/null 2>&1
  else
    docker info >/dev/null 2>&1
  fi
}

# ask "<prompt>" <default y|n> -- MDL_ASSUME_YES answers every one of these, which
# is what an unattended run needs; the app-creation guard deliberately does not use
# it, because writing a few hundred files into an unnamed directory should stay a
# question a person answered.
ask() {
  local question="$1" default="$2" reply
  if [ -n "${MDL_ASSUME_YES:-}" ]; then
    printf '%syes  %s(MDL_ASSUME_YES)%s\n' "$question" "$C_GREY" "$C_RESET"
    return 0
  fi
  printf '%s' "$question"
  read -r reply
  case "${reply:-$default}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

docker_install_command() {
  case "$(pkg_manager)" in
    winget) echo "winget install -e --accept-package-agreements --accept-source-agreements --id Docker.DockerDesktop" ;;
    brew)   echo "brew install --cask docker" ;;
    apt)    echo "${SUDO}apt-get update -qq && ${SUDO}apt-get install -y docker.io" ;;
    dnf)    echo "${SUDO}dnf install -y docker" ;;
  esac
}

# Docker Desktop is a GUI application: started in the foreground it never returns,
# and the installer sits there until someone quits Docker. So it is launched
# detached -- `cmd //c start` on Windows, `open -a` on macOS, both of which hand
# control straight back. Learned the hard way: the first version of this hung
# immediately after "Start it for you now?".
docker_start_command() {
  if [ "$IS_WINDOWS" = "1" ]; then
    # PROGRAMFILES carries backslashes; bash wants them the other way round before
    # it can run the thing.
    local program_files="${PROGRAMFILES:-C:\\Program Files}"
    echo "cmd //c start \"\" \"${program_files//\\//}/Docker/Docker/Docker Desktop.exe\""
  elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    echo "open -a Docker"
  else
    echo "${SUDO}systemctl start docker"
  fi
}

# PostgreSQL. `mxcli run --local` is Postgres-only in code -- the binary refuses
# anything else outright ("--ensure-db only supports PostgreSQL") -- so this is the
# database whether or not Docker is in the picture. Windows keeps psql off the PATH
# the same way it keeps Python and the JDK off it.
psql_path() {
  if have psql; then command -v psql; return 0; fi
  local candidate
  # `[ -x … ] && …` as a loop body's last statement aborts the script under set -e
  # when it is false. Every test here is written as a guard clause for that reason.
  for candidate in "/c/Program Files/PostgreSQL"/*/bin/psql.exe \
                   /opt/homebrew/opt/postgresql@*/bin/psql /usr/lib/postgresql/*/bin/psql; do
    [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# Which login actually works. `--ensure-db` used to create the `mendix` role inside
# its container; a PostgreSQL that was installed by hand has only its superuser, so
# both are tried and the winner is recorded.
#
# Every call passes -w. Without it psql *prompts* for a password rather than failing,
# and an installer that stops dead on "Password for user postgres:" is worse than one
# that reports it could not connect.
postgres_login() {       # echoes "<user>:<password>" for a login that answers
  local psql candidate password host="${MDL_DB_HOST:-127.0.0.1}"
  host="${host%%:*}"
  psql="$(psql_path)" || return 1
  for candidate in "${MDL_DB_USER:-mendix}:${MDL_DB_PASSWORD:-mendix}" \
                   "postgres:${PGPASSWORD:-postgres}" "postgres:" "${USER:-}:"; do
    password="${candidate#*:}"
    PGPASSWORD="$password" "$psql" -w -h "$host" -U "${candidate%%:*}" \
      -d postgres -tAc 'SELECT 1' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

postgres_answers() { postgres_login >/dev/null 2>&1; }

# Ask for a superuser once, and only when nothing else worked. This is the piece
# that lets the installer finish the database on its own: it can create a role and a
# database, but it cannot discover a password that already exists, and guessing or
# rewriting pg_hba.conf to get in are both worse than asking.
#
# The superuser password is used for exactly one command and never written down;
# what lands in tests/harness.env is the app's own role.
postgres_ask_superuser() {
  local psql user password host="${MDL_DB_HOST:-127.0.0.1}"
  host="${host%%:*}"
  psql="$(psql_path)" || return 1
  [ -t 0 ] || return 1
  [ "$UI_TTY" = 1 ] || return 1

  ui_clear
  printf '\n  %s%s%s PostgreSQL is running, but none of the usual logins worked.\n' \
    "$C_YELLOW" "$I_WARN" "$C_RESET"
  printf '    Give me a superuser once and I will create the %s%s%s role and this\n' \
    "$C_BOLD" "${MDL_DB_USER:-mendix}" "$C_RESET"
  printf '    project'"'"'s database. The password is used for that one command and is\n'
  printf '    never written to disk.\n\n'
  printf '    Superuser name [postgres]: '
  read -r user
  user="${user:-postgres}"
  printf '    Password for %s (not echoed): ' "$user"
  read -r -s password
  printf '\n\n'

  if ! PGPASSWORD="$password" "$psql" -w -h "$host" -U "$user" \
         -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
    ui_note "that $user login was refused -- nothing was changed"
    return 1
  fi

  local wanted="${MDL_DB_USER:-mendix}" wanted_pass="${MDL_DB_PASSWORD:-mendix}"
  PGPASSWORD="$password" "$psql" -w -h "$host" -U "$user" -d postgres \
    -c "CREATE ROLE \"$wanted\" LOGIN PASSWORD '$wanted_pass' CREATEDB" >/dev/null 2>&1 || true
  # Already there with a different password? Then set it, since we are superuser.
  PGPASSWORD="$password" "$psql" -w -h "$host" -U "$user" -d postgres \
    -c "ALTER ROLE \"$wanted\" LOGIN PASSWORD '$wanted_pass' CREATEDB" >/dev/null 2>&1 || true

  if PGPASSWORD="$wanted_pass" "$psql" -w -h "$host" -U "$wanted" \
       -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
    ui_note "PostgreSQL role $wanted created"
    return 0
  fi
  DEPS_MISSING+=("PostgreSQL -- the $wanted role could not be created; see your server log.")
  return 1
}

# The role the app logs in as. Created only when the login that answered can create
# roles; otherwise the harness simply runs as whoever answered.
ensure_postgres_role() {
  local login user password psql host="${MDL_DB_HOST:-127.0.0.1}"
  host="${host%%:*}"
  login="$(postgres_login)" || return 1
  user="${login%%:*}"; password="${login#*:}"
  psql="$(psql_path)" || return 1
  if [ "$user" = "${MDL_DB_USER:-mendix}" ]; then
    printf '%s\n' "$login"; return 0
  fi
  local wanted="${MDL_DB_USER:-mendix}" wanted_pass="${MDL_DB_PASSWORD:-mendix}"
  if PGPASSWORD="$password" "$psql" -w -h "$host" -U "$user" -d postgres \
       -c "CREATE ROLE \"$wanted\" LOGIN PASSWORD '$wanted_pass' CREATEDB" >/dev/null 2>&1; then
    printf '%s:%s\n' "$wanted" "$wanted_pass"; return 0
  fi
  # The role may already exist with another password, or we may not be superuser.
  if PGPASSWORD="$wanted_pass" "$psql" -w -h "$host" -U "$wanted" \
       -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
    printf '%s:%s\n' "$wanted" "$wanted_pass"; return 0
  fi
  printf '%s\n' "$login"
}

# The mode, written where the harness reads it. Beside tests/credentials.env, and
# rewritten rather than appended so a second install does not stack up duplicates.
write_harness_env() {    # write_harness_env <mendix-install-dir>
  local mxbuild="$1" db_name psql login jdk jdk_home=""
  db_name="$(basename "$APP" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]//g')"
  psql="$(psql_path || true)"
  login="$(ensure_postgres_role || true)"
  jdk="$(jdk_find 21 || jdk_find 17 || true)"
  [ -n "$jdk" ] && jdk_home="$(jdk_spacefree_home "$jdk" || true)"
  if [ -n "$login" ]; then
    MDL_DB_USER="${login%%:*}"
    MDL_DB_PASSWORD="${login#*:}"
  fi
  mkdir -p "$APP/tests"
  {
    printf '# Written by install.sh -- how this project is built and run.\n'
    printf '# Read by tests/portable.sh, so every harness script sees it. The\n'
    printf '# environment still wins: export a value to override for one run.\n'
    printf 'MDL_NO_DOCKER=1\n'
    [ -n "$mxbuild" ] && printf 'MDL_MXBUILD_PATH="%s"\n' "$mxbuild"
    # mxcli's --db-host is host:port and refuses a bare host with
    # "missing port in address". gate.sh splits it again for psql.
    printf 'MDL_DB_HOST="%s"\n' "${MDL_DB_HOST:-127.0.0.1:5432}"
    printf 'MDL_DB_NAME="%s"\n' "$db_name"
    printf 'MDL_DB_USER="%s"\n' "${MDL_DB_USER:-mendix}"
    printf 'MDL_DB_PASSWORD="%s"\n' "${MDL_DB_PASSWORD:-mendix}"
    [ -n "$psql" ] && [ "$psql" != "psql" ] && printf 'MDL_PSQL="%s"\n' "$psql"
    if [ -n "$jdk_home" ]; then
      printf '\n# The JDK mxcli hands to mxbuild. mxbuild splits its own arguments on\n'
      printf '# spaces, so a path like "C:\\Program Files (Arm)\\zulu21" arrives as four\n'
      printf '# unrecognised arguments and serve mode exits printing usage. This one has\n'
      printf '# no spaces (a junction, created by install.sh).\n'
      printf 'JAVA_HOME="%s"\n' "$jdk_home"
      printf 'export JAVA_HOME\n'
    fi
    if [ "$IS_WINDOWS" = "1" ]; then
      printf '\n# How the gate boots the app. `mxcli run --local` cannot boot on Windows:\n'
      printf '# its liveness probe is os.Process.Signal(0), which Windows rejects for every\n'
      printf '# signal but Kill, so a healthy mxbuild and a healthy runtime both read as\n'
      printf '# "exited during startup". tests/run-app.sh drives mxbuild and the standalone\n'
      printf '# runtime directly instead. Delete this line once a fixed mxcli is installed.\n'
      printf 'MDL_BOOT_COMMAND="bash tests/run-app.sh"\n'
    fi
  } > "$APP/tests/harness.env"
  # On Windows the directory is a Studio Pro install; elsewhere it is usually the
  # cached mxbuild. Name what it actually is rather than guessing.
  case "$mxbuild" in
    *"/Program Files/Mendix/"*) no_docker_mode="Studio Pro ${mxbuild##*/}" ;;
    *"/Mendix Studio Pro"*)     no_docker_mode="Studio Pro ${mxbuild##*/}" ;;
    *)                          no_docker_mode="mxbuild ${mxbuild##*/}" ;;
  esac
}

# Docker is a prerequisite, so it is installed when missing rather than offered.
# It is still a download, then a launch, then a licence click, then a daemon that
# takes a minute -- and the last two cannot be automated, so this installs it,
# starts it, waits for the socket, and says plainly what is left to do by hand.
docker_walkthrough() {
  local command
  command="$(docker_install_command)"
  if [ -z "$command" ]; then
    DEPS_MISSING+=("Docker -- no package manager here; install Docker Desktop by hand")
    return 1
  fi

  ui_clear
  printf '\n  %s%s%s Docker is not installed. Installing it.\n' "$C_YELLOW" "$I_WARN" "$C_RESET"
  printf '    Running:  %s%s%s\n\n' "$C_CYAN" "$command" "$C_RESET"
  ui_sub "installing Docker (this is a large download)"
  if ! dep_run "$command"; then
    ui_clear
    printf '  %s%s%s The install command failed. Its output:\n' "$C_RED" "$I_FAIL" "$C_RESET"
    tail -8 "$DEPS_LOG" 2>/dev/null | sed 's/^/      /'
    DEPS_MISSING+=("Docker -- install failed, see $DEPS_LOG")
    return 1
  fi
  DEPS_INSTALLED=$(( DEPS_INSTALLED + 1 ))

  # Installed is not running. Docker Desktop in particular needs a first launch,
  # a licence acceptance and a WSL2 backend before the socket answers.
  ui_clear
  printf '  %s%s%s Docker is installed. Three things it still needs from you:\n\n' "$C_GREEN" "$I_OK" "$C_RESET"
  if [ "$IS_WINDOWS" = "1" ]; then
    printf '      1. Start Docker Desktop from the Start menu.\n'
  else
    printf '      1. Start Docker.  %s%s%s\n' "$C_GREY" "$(docker_start_command)" "$C_RESET"
  fi
  printf '      2. Accept its licence the first time it opens.\n'
  if [ "$IS_WINDOWS" = "1" ]; then
    printf '      3. Let it enable the WSL2 backend when it asks. A reboot may be needed;\n'
    printf '         if so, reboot and re-run this installer -- it will pick up where it left off.\n'
  else
    printf '      3. Wait for the whale in the menu bar to stop animating.\n'
  fi
  printf '\n'

  if [ "$IS_WINDOWS" = "1" ] || [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    # Detached and time-boxed: a launcher that decides to stay in the foreground
    # must not take the installation down with it.
    ui_sub "starting Docker Desktop"
    ( dep_run "$(docker_start_command)" || true ) >/dev/null 2>&1 &
    sleep 2
  fi

  if [ -n "${MDL_DEPS_DRY_RUN:-}" ]; then
    ui_note "would wait here for the Docker daemon to answer"
    return 0
  fi

  # Ctrl-C stops the waiting, not the installation: the skills and hooks still have
  # to land, and Docker is not needed for any of that.
  local stop_waiting=0
  trap 'stop_waiting=1' INT
  printf '    Waiting for the Docker daemon (Ctrl-C to stop waiting) '
  local waited=0
  while [ "$waited" -lt "${DOCKER_WAIT:-180}" ] && [ "$stop_waiting" = "0" ]; do
    if docker_ready; then
      trap - INT
      printf '\n'
      ui_clear
      printf '  %s%s%s Docker is up.\n\n' "$C_GREEN" "$I_OK" "$C_RESET"
      return 0
    fi
    printf '.'
    sleep 3
    waited=$(( waited + 3 ))
  done
  trap - INT
  printf '\n'
  if [ "$stop_waiting" = "1" ]; then
    DEPS_MISSING+=("Docker -- installed; you stopped waiting for the daemon. When it is up: docker info")
    return 1
  fi
  DEPS_MISSING+=("Docker -- installed, but the daemon did not answer within ${DOCKER_WAIT:-180}s.")
  DEPS_MISSING+=("          Start Docker Desktop, accept the licence, then: docker info")
  return 1
}

# `mxcli run --local` links the cached runtime into the mxbuild bundle with a
win_path() {             # win_path <msys-path> -- echo the Windows form
  case "$1" in
    /[a-zA-Z]/*) printf '%s:%s\n' \
      "$(printf '%s' "${1:1:1}" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "${1:2}" | tr '/' '\\')" ;;
    *) printf '%s\n' "$1" | tr '/' '\\' ;;
  esac
}

# *symlink*, and unprivileged Windows refuses to create one unless Developer Mode is
# on: "A required privilege is not held by the client". A junction is the same thing
# for directories and needs no privilege at all, so make one and let mxcli find it
# already there. Observed on Windows 11 with Studio Pro 11.12.1.
ensure_runtime_junction() {   # ensure_runtime_junction <version>
  [ "$IS_WINDOWS" = "1" ] || return 0
  local version="$1" runtime link
  runtime="$HOME/.mxcli/runtime/$version/runtime"
  link="$HOME/.mxcli/mxbuild/$version/runtime"
  [ -d "$runtime" ] || return 0
  [ -e "$link" ] && return 0
  mkdir -p "$HOME/.mxcli/mxbuild/$version" 2>/dev/null || return 0
  local runtime_win link_win drive
  drive="$(printf '%s' "${HOME:1:1}" | tr '[:lower:]' '[:upper:]')"
  runtime_win="$(printf '%s:%s' "$drive" "${runtime:2}" | tr '/' '\\')"
  link_win="$(printf '%s:%s' "$drive" "${link:2}" | tr '/' '\\')"
  cmd //c mklink //J "$link_win" "$runtime_win" >> "$DEPS_LOG" 2>&1 || true
  [ -e "$link" ] && ui_note "runtime linked into the mxbuild cache (junction, no admin needed)"
  return 0
}

# Studio Pro ships more than the modeler: mxbuild shells out to Gradle to compile
# the app's Java, and the cache `mxcli setup mxbuild` builds holds only modeler/ and
# runtime/. Without gradle-8.5 beside them every build fails with "No supported
# Gradle installation found" -- after mxbuild has already started and answered, so it
# reads as a model problem rather than a missing directory. Junctions, so nothing is
# copied. Observed on Windows 11 ARM64 with Studio Pro 11.12.1.
ensure_studio_support_junctions() {   # ensure_studio_support_junctions <version> <studio-dir>
  [ "$IS_WINDOWS" = "1" ] || return 0
  local version="$1" studio="$2" name target link linked=""
  [ -d "$studio" ] || return 0
  mkdir -p "$HOME/.mxcli/mxbuild/$version" 2>/dev/null || return 0
  for name in gradle-8.5 OpenJDK WebView2; do
    target="$studio/$name"
    link="$HOME/.mxcli/mxbuild/$version/$name"
    [ -d "$target" ] || continue
    [ -e "$link" ] && continue
    cmd //c mklink //J "$(win_path "$link")" "$(win_path "$target")" >> "$DEPS_LOG" 2>&1 || true
    [ -e "$link" ] && linked="$linked $name"
  done
  [ -n "$linked" ] && ui_note "linked into the mxbuild cache:$linked"
  return 0
}

# Studio Pro for Windows on ARM ships its bundled tools as win-arm64 only, but
# mxbuild asks for win-x64 regardless -- so `mxbuild --serve` dies before it listens:
#
#   ERROR: System.ComponentModel.Win32Exception (2): An error occurred trying to
#   start process '...\modeler\tools\deno\win-x64\deno.exe'
#
# The arm64 binaries are the right ones for this machine; only the name is wrong.
# A junction gives mxbuild the name it looks for. Reproduced on Studio Pro 11.12.1.
ensure_tool_arch_aliases() {  # ensure_tool_arch_aliases <studio-dir>
  [ "$IS_WINDOWS" = "1" ] || return 0
  local studio="$1" tool dir aliased=""
  for tool in deno node; do
    dir="$studio/modeler/tools/$tool"
    [ -d "$dir/win-arm64" ] || continue
    [ -e "$dir/win-x64" ] && continue
    cmd //c mklink //J "$(win_path "$dir/win-x64")" "$(win_path "$dir/win-arm64")" >> "$DEPS_LOG" 2>&1 || true
    [ -e "$dir/win-x64" ] && aliased="$aliased $tool"
  done
  [ -n "$aliased" ] && ui_note "win-x64 aliases for Studio Pro's arm64 tools:$aliased"
  return 0
}

# mxbuild splits its own command line on spaces. --java-home=C:\Program Files
# (Arm)\zulu21 reaches it as four unrecognised arguments, so it prints its usage and
# exits -- which mxcli reports as "mxbuild --serve exited during startup", naming
# neither the JDK nor the spaces. Hand it a path with none. A junction under
# LOCALAPPDATA needs no privilege; C:\ is the fallback for a username with a space.
jdk_spacefree_home() {   # jdk_spacefree_home <path-to-java> -- echo a space-free home
  [ "$IS_WINDOWS" = "1" ] || return 1
  local java="$1" home win link
  home="${java%/bin/java$EXE}"
  [ "$home" = "$java" ] && home="${java%/java$EXE}"
  win="$(win_path "$home")"
  case "$win" in
    *" "*) ;;
    *) printf '%s\n' "${win//\\//}"; return 0 ;;
  esac
  link="${LOCALAPPDATA:-$HOME/AppData/Local}"
  link="${link//\\//}/mxcli-jdk"
  case "$link" in *" "*) link="/c/mxcli-jdk" ;; esac
  [ -e "$link" ] || cmd //c mklink //J "$(win_path "$link")" "$win" >> "$DEPS_LOG" 2>&1 || true
  [ -x "$link/bin/java$EXE" ] || return 1
  printf '%s\n' "$(win_path "$link" | tr '\\' '/')"
}

# Reported, never installed: a reboot, a daemon or a licence click stands between
# the command and a working tool, so claiming to have done it would be a lie.
dep_report_only() {      # dep_report_only <label> <detect> <winget> <brew> <apt>
  eval "$2" >/dev/null 2>&1 && return 0
  local command=""
  case "$(pkg_manager)" in
    winget) command="winget install -e --id $3" ;;
    brew)   command="brew install $4" ;;
    apt)    command="${SUDO}apt-get install -y $5" ;;
    dnf)    command="${SUDO}dnf install -y $5" ;;
  esac
  DEPS_MISSING+=("$1 -- ${command:-install it by hand}  (not installed for you)")
  return 1
}

# The same shape as .claude/bootstrap-mxcli.sh: the release asset name is
# deterministic, so no mxcli is needed to fetch the first mxcli.
mxcli_release_url() {
  local os arch
  case "$(uname -s 2>/dev/null)" in
    Darwin)               os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *)                    os=linux ;;
  esac
  case "$(uname -m 2>/dev/null)" in
    arm64|aarch64) arch=arm64 ;;
    *)             arch=amd64 ;;
  esac
  printf 'https://github.com/mendixlabs/mxcli/releases/download/%s/mxcli-%s-%s%s\n' \
    "${MXCLI_TAG:-nightly}" "$os" "$arch" "$EXE"
}

# Windows has no CDN mxbuild: the Mendix CDN publishes a Linux binary only, and
# mxcli says so and refuses. The Windows source of `mx` is Studio Pro's own
# modeler, so what Studio Pro is installed decides what can be created or checked.
# Studio Pro installs in two places, and which one depends on the version: the older
# ones land in Program Files, while 10.x and 11.x default to a per-user directory
# under %LOCALAPPDATA%. Looking in only the first found 9.24 on a machine that also
# had 11.12.1, and quietly built the app at 9.24 -- so both roots are searched.
studio_pro_roots() {
  local local_app="${LOCALAPPDATA:-}"
  local_app="${local_app//\\//}"
  printf '%s\n' "/c/Program Files/Mendix" "/c/Program Files (x86)/Mendix"
  [ -n "$local_app" ] && printf '%s\n' "$local_app/Programs/Mendix"
}

studio_pro_versions() {
  local root dir
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    for dir in "$root"/*/; do
      [ -x "$dir/modeler/mx.exe" ] || continue
      printf '%s\n' "$(basename "$dir")"
    done
  done < <(studio_pro_roots) | sort -V -u
}

# What *mxcli* can see, which is not the same thing. `mxcli new` has no
# --mxbuild-path and searches only C:\Program Files\Mendix, so a Studio Pro that
# lives in the per-user directory is invisible to it: it silently falls back to
# whatever is in Program Files and stamps the project with that version instead.
# Observed on Windows 11 -- asked for 11.12.1, got 9.24.37.77045.
studio_pro_mx_visible_to_mxcli() {   # <version-prefix>
  local dir
  for dir in "/c/Program Files/Mendix"/"$1"*/; do
    [ -x "$dir/modeler/mx.exe" ] || continue
    printf '%s\n' "$dir/modeler/mx.exe"
    return 0
  done
  return 1
}

# One junction, one UAC prompt, and mxcli can see the install for good. A junction
# is a directory pointer: no copy, no disk, and `rmdir` undoes it.
offer_studio_pro_junction() {   # <version> <path-to-per-user-mx.exe>
  local version="$1" mx="$2" install_dir target_win link_win
  install_dir="$(cd "$(dirname "$(dirname "$mx")")" && pwd)"
  # /c/Users/... -> C:\Users\...  . Parameter expansion and tr, because sed's \U is
  # GNU-only and this file also has to run on macOS.
  local drive rest
  drive="$(printf '%s' "${install_dir:1:1}" | tr '[:lower:]' '[:upper:]')"
  rest="${install_dir:2}"
  target_win="$(printf '%s:%s' "$drive" "$rest" | tr '/' '\\')"
  link_win="C:\\Program Files\\Mendix\\$version"

  ui_clear
  printf '\n  %s%s%s Studio Pro %s is installed where mxcli cannot see it.\n\n' \
    "$C_YELLOW" "$I_WARN" "$C_RESET" "$version"
  printf '    mxcli looks only in %sC:\\Program Files\\Mendix%s, and yours is at\n' "$C_BOLD" "$C_RESET"
  printf '    %s%s%s. Creating the app works around that,\n' "$C_CYAN" "$target_win" "$C_RESET"
  printf '    but %srunning%s it does not -- mxcli resolves mxbuild on its own there.\n\n' \
    "$C_BOLD" "$C_RESET"
  printf '    A directory junction fixes it permanently. No copy, no disk used:\n'
  printf '      %smklink /J "%s" "%s"%s\n\n' "$C_CYAN" "$link_win" "$target_win" "$C_RESET"
  printf '    It needs administrator rights, so Windows will ask you to confirm.\n\n'

  if [ -e "/c/Program Files/Mendix/$version" ]; then
    return 0
  fi
  if ! ask "    Create it now? [Y/n] " y; then
    DEPS_MISSING+=("Studio Pro $version -- not visible to mxcli, so the app cannot be booted.")
    DEPS_MISSING+=("                 mklink /J \"$link_win\" \"$target_win\"   (as administrator)")
    return 1
  fi

  ui_sub "asking Windows for permission"
  powershell.exe -NoProfile -Command \
    "Start-Process cmd.exe -Verb RunAs -Wait -ArgumentList '/c','mklink','/J','\"$link_win\"','\"$target_win\"'" \
    >> "$DEPS_LOG" 2>&1 || true
  if [ -e "/c/Program Files/Mendix/$version" ]; then
    ui_note "Studio Pro $version linked into Program Files; mxcli can see it now"
    return 0
  fi
  DEPS_MISSING+=("Studio Pro $version -- the junction was not created, so the app cannot boot.")
  DEPS_MISSING+=("                 mklink /J \"$link_win\" \"$target_win\"   (as administrator)")
  return 1
}

studio_pro_mx() {        # studio_pro_mx <version-prefix> -- echo the matching mx.exe
  local version="$1" root dir
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    for dir in "$root"/"$version"*/; do
      [ -x "$dir/modeler/mx.exe" ] || continue
      printf '%s\n' "$dir/modeler/mx.exe"
      return 0
    done
  done < <(studio_pro_roots)
  return 1
}

# The browser is not `npx playwright install` -- that fails on Linux arm64, and
# `playwright-cli install` initialises a workspace rather than a browser. The
# devcontainer's own line is the one that works.
playwright_browser_command() {
  printf 'node "$(npm root -g)/@playwright/cli/node_modules/playwright-core/cli.js" install chromium chromium-headless-shell\n'
}

# The JDK the runtime needs follows the project's Mendix version, not a constant:
# `mxcli run --help` says 21 up to Mendix 11.13 and 25 from 11.14, and Mendix 9
# wants 11. Studio Pro's own prerequisite installs one, so a machine that can open
# the project almost always has a usable JDK already.
jdk_major_for() {         # jdk_major_for <mendix-version>
  case "${1%%.*}" in
    ""|8|9) echo 11 ;;
    10)     echo 21 ;;
    11)     case "$1" in 11.1[4-9]*|11.[2-9][0-9]*) echo 25 ;; *) echo 21 ;; esac ;;
    *)      echo 25 ;;
  esac
}

java_major() {            # java_major <path-to-java> -- echo the major version
  "$1" -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p'
}

# Found wherever it is, not merely wherever the PATH points. Observed on Windows
# 11: three JDKs installed, none on the PATH, and JAVA_HOME pointing at a bin
# directory rather than the home -- so both shapes are tried.
jdk_find() {              # jdk_find <wanted-major> -- echo a matching java
  local want="$1" candidate found
  local -a candidates=()
  if [ -n "${JAVA_HOME:-}" ]; then
    local home="${JAVA_HOME//\\//}"
    candidates+=("$home/bin/java$EXE" "$home/java$EXE" "$home/bin/java" "$home/java")
  fi
  have java && candidates+=("$(command -v java)")
  candidates+=(
    "/c/Program Files/Eclipse Adoptium"*/jdk-*/bin/java.exe
    "/c/Program Files/Java"/jdk-*/bin/java.exe
    "/c/Program Files/Microsoft"/jdk-*/bin/java.exe
    "/c/Program Files"*/zulu*/bin/java.exe
    "/c/Program Files"*/zulu*/java.exe
    /usr/lib/jvm/*/bin/java
    /Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java
  )
  for candidate in "${candidates[@]}"; do
    [ -x "$candidate" ] || continue
    found="$(java_major "$candidate")"
    [ "$found" = "$want" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

playwright_browser_present() {
  local root
  for root in "$HOME/Library/Caches/ms-playwright" "$HOME/.cache/ms-playwright" \
              "${LOCALAPPDATA:-}/ms-playwright" "${PLAYWRIGHT_BROWSERS_PATH:-}"; do
    [ -n "$root" ] || continue
    set -- "$root"/chromium_headless_shell-*
    [ -e "$1" ] && return 0
  done
  return 1
}

APP_ARG=""
CREATE_APP=1
WITH_DEPS=0
for arg in "$@"; do
  case "$arg" in
    --no-app) CREATE_APP=0 ;;
    --with-deps) WITH_DEPS=1 ;;
    -h|--help)
      printf 'bash install.sh [path-to-project] [--no-app] [--with-deps]\n\n'
      printf '  path-to-project  where to install (default: the current directory,\n'
      printf '                   or the parent project when run from inside the bundle)\n'
      printf '  --no-app         never create a Mendix app; require one to be there already\n'
      printf '  --with-deps      install missing prerequisites (Python, Node, playwright-cli,\n'
      printf '                   its browser, mxcli, MxBuild) with this machine'"'"'s package manager.\n'
      printf '                   Without it they are only reported. Docker and the JDK are never\n'
      printf '                   installed -- both need a reboot or a licence click.\n\n'
      printf '  MX_VERSION=11.12.1  APP_NAME=<name>   env overrides when an app is created\n'
      printf '  MDL_DEPS_DRY_RUN=1                    print the install commands, run none\n'
      printf '  MDL_ASSUME_YES=1                      answer the prerequisite prompts with yes\n'
      exit 0 ;;
    -*) ui_fail "Unknown option: $arg" "Run with --help to see what this takes." ;;
    *)
      if [ -z "$APP_ARG" ]; then APP_ARG="$arg"; else ui_fail "Only one path can be given (got \"$APP_ARG\" and \"$arg\")."; fi ;;
  esac
done

ui_banner "$version"

if [ -n "$APP_ARG" ]; then APP="$APP_ARG"; else APP="$PWD"; fi
[ -d "$APP" ] || ui_fail "No such directory: $APP"
APP="$(cd "$APP" && pwd)"

# The bundle cannot be its own target -- it would install into itself and then
# try to create a Mendix app on top of the payload. But standing in the bundle
# and running it is exactly what someone does after copying dist/ into their
# app, so with no path named, install into the directory the bundle sits in.
# A path that was named explicitly is never second-guessed.
target_inferred=0
looks_like_project() {
  [ -n "$(find "$1" -maxdepth 1 -name '*.mpr' -print -quit 2>/dev/null)" ] && return 0
  for marker in CLAUDE.md AGENTS.md .ai-context .claude mxcli; do
    [ -e "$1/$marker" ] && return 0
  done
  return 1
}

case "$APP" in
  "$SRC"|"$SRC"/*)
    if [ -n "$APP_ARG" ]; then
      ui_fail "install.sh installs INTO a Mendix project; that path is the bundle itself." \
              "$APP" \
              "" \
              "Name the project instead:" \
              "  bash $SRC/install.sh /path/to/project"
    fi
    parent="$(cd "$SRC/.." && pwd)"
    if [ "$parent" = "/" ] || [ "$parent" = "$HOME" ]; then
      ui_fail "Run from inside the bundle, but $parent is not a project." \
              "Name the project:  bash $SRC/install.sh /path/to/project"
    fi
    if ! looks_like_project "$parent"; then
      ui_fail "Run from inside the bundle, and $parent does not look like a Mendix project." \
              "No .mpr, CLAUDE.md, .claude/ or .ai-context/ there." \
              "" \
              "Name the project:  bash $SRC/install.sh /path/to/project"
    fi
    APP="$parent"
    target_inferred=1 ;;
esac

# A Mendix project is the only sensible target: the lint rules and checkers read an
# .mpr. With no app here, make one -- an empty Mendix app is a two-command chore that
# otherwise stands between someone and a working harness. --no-app declines it.
#
# Env: MX_VERSION (11.12.1), APP_NAME (defaults to the directory name).
mpr_count=$(find "$APP" -maxdepth 1 -name '*.mpr' | wc -l | tr -d ' ')
if [ "$mpr_count" = "0" ] && [ "$CREATE_APP" = "0" ]; then
  ui_fail "No .mpr in $APP" \
          "Point this at a Mendix project, or drop --no-app to have one created here."
fi

if [ "$target_inferred" = 1 ]; then
  printf '  %s%s target%s %s  %s(the project this bundle sits in)%s\n' \
    "$C_GREY" "$I_BOX" "$C_RESET" "$APP" "$C_GREY" "$C_RESET"
else
  printf '  %s%s target%s %s\n' "$C_GREY" "$I_BOX" "$C_RESET" "$APP"
fi
printf '\n'

# Creating a Mendix app takes a minute and writes a few hundred files. Doing that
# in a directory the caller never named deserves a question, not a default.
if [ "$target_inferred" = 1 ] && [ "$mpr_count" = "0" ] && [ "$CREATE_APP" = "1" ]; then
  if [ -t 0 ] && [ "$UI_TTY" = 1 ]; then
    printf '  %s%s%s There is no Mendix app in %s.\n' "$C_YELLOW" "$I_WARN" "$C_RESET" "$APP"
    printf '    Create an empty one there now? [y/N] '
    read -r reply
    case "$reply" in
      y|Y|yes|YES) printf '\n' ;;
      *) ui_fail "Nothing installed." "Name a project with an app, or pass --no-app to install without creating one." ;;
    esac
  else
    ui_fail "No Mendix app in $APP, and the target was inferred rather than named." \
            "Name it, so creating an app is a deliberate choice:" \
            "  bash $SRC/install.sh $APP"
  fi
fi

# Fixed before the first step runs, so the bar never discovers extra work.
if [ "$mpr_count" = "0" ]; then ui_plan 12; else ui_plan 11; fi

# ---------------------------------------------------------------------------
# Prerequisites, before anything else -- creating the app needs mxcli, and the
# hook merges need Python. Missing tools are collected and reported in the
# summary rather than printed here, so the step count stays honest.
# ---------------------------------------------------------------------------
DEPS_LOG="${TMPDIR:-/tmp}"; DEPS_LOG="${DEPS_LOG%/}/mdl-skills-deps.log"
: > "$DEPS_LOG" 2>/dev/null || DEPS_LOG=/dev/null

ui_begin "checking prerequisites"

# Python first: this installer merges every host's hook file with it.
dep_need "Python 3" "mdl_find_python >/dev/null" "Python.Python.3.12" "python" "python3" || true
[ -n "$PY" ] || PY="$(mdl_find_python || true)"
[ -n "$PY" ] || ui_fail "This installer needs Python 3 -- it merges the host hook files." \
                        "Re-run with --with-deps, or install it and try again." \
                        "On Windows note that the python.org installer leaves \"Add python.exe" \
                        "to PATH\" unticked -- an installed but invisible Python looks the same."

# The browser-test chain: Node, then the CLI, then the headless shell it drives.
dep_need "Node.js" "have node" "OpenJS.NodeJS.LTS" "node" "nodejs npm" || true
# In a dry run nothing was really installed, so npm is still absent -- but the
# point of a dry run is to see every command, so the chain is walked anyway.
if have npm || [ -n "${MDL_DEPS_DRY_RUN:-}" ]; then
  # Pinned to the version the devcontainer pins; @latest has broken this before.
  dep_apply "playwright-cli" "have playwright-cli" "npm install -g @playwright/cli@0.1.15" || true
  if have playwright-cli || [ -n "${MDL_DEPS_DRY_RUN:-}" ]; then
    dep_apply "Chromium headless shell" "playwright_browser_present" "$(playwright_browser_command)" || true
  fi
fi

# mxcli. The release asset name is deterministic, so the first one needs no mxcli
# to fetch it; an mxcli that is already here does the job properly instead.
mxcli_here=""
for candidate in "$APP/mxcli$EXE" "$(command -v "mxcli$EXE" 2>/dev/null || true)" \
                 "$SRC/../mxcli$EXE" "$SRC/mxcli$EXE"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { mxcli_here="$candidate"; break; }
done
if [ -z "$mxcli_here" ]; then
  dep_apply "mxcli" '[ -x "$APP/mxcli$EXE" ]' \
    "curl -fsSL -o \"$APP/mxcli$EXE\" \"$(mxcli_release_url)\" && chmod +x \"$APP/mxcli$EXE\"" || true
fi

# MxBuild for the version this project will be. Without it `mxcli new` falls back
# to whatever Studio Pro is installed -- observed on a Windows 11 VM, where a
# Mendix 9.24 Studio Pro silently produced a 9.24 project from a request for
# 11.12.1 -- and `mx check` cannot run at all.
mxcli_now=""
for candidate in "$APP/mxcli$EXE" "$mxcli_here"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { mxcli_now="$candidate"; break; }
done
if [ -n "$mxcli_now" ]; then
  if [ "$mpr_count" = "0" ]; then
    # Same rule the app creation below uses, so the two never disagree about which
    # version this machine is going to produce.
    if [ -n "${MX_VERSION:-}" ]; then
      want_mx="$MX_VERSION"
    elif [ "$IS_WINDOWS" = "1" ]; then
      want_mx="$(studio_pro_versions | tail -1)"
      want_mx="${want_mx:-11.12.1}"
    else
      want_mx="11.12.1"
    fi
  else
    want_mx="$("$PY" - "$APP" <<'PY_WANT' 2>/dev/null || true
import glob, os, sqlite3, sys
mprs = glob.glob(os.path.join(sys.argv[1], "*.mpr"))
if mprs:
    try:
        con = sqlite3.connect("file:%s?mode=ro" % mprs[0], uri=True)
        print(con.execute("select * from _MetaData limit 1").fetchone()[1])
    except Exception:
        pass
PY_WANT
)"
  fi
  if [ -n "$want_mx" ]; then
    if [ "$IS_WINDOWS" = "1" ]; then
      # Nothing to install: `mxcli setup mxbuild` on Windows exits 1 with
      # "mxbuild from the Mendix CDN is a Linux binary and cannot run natively on
      # windows" -- verified on Windows 11. Studio Pro is the only source.
      if ! studio_pro_mx "$want_mx" >/dev/null; then
        installed_studio="$(studio_pro_versions | tr '\n' ' ')"
        DEPS_MISSING+=("Studio Pro $want_mx -- needed for \`mx check\` and to create an app at that version.")
        DEPS_MISSING+=("               installed here: ${installed_studio:-none}. Set MX_VERSION to one of those,")
        DEPS_MISSING+=("               or install Studio Pro $want_mx. (The Mendix CDN's mxbuild is Linux-only.)")
      fi
    else
      dep_apply "MxBuild $want_mx" \
        "[ -x \"$HOME/.mxcli/mxbuild/$want_mx/modeler/mx\" ]" \
        "\"$mxcli_now\" setup mxbuild --version \"$want_mx\"" || true
    fi
    # Cache the runtime and prove the app can actually boot later. The first attempt
    # downloads it and may then fail on the symlink; the junction fixes that, and the
    # second attempt is the one that has to succeed.
    if [ "$IS_WINDOWS" = "1" ] && [ -n "${no_docker_candidate:-1}" ]; then
      ui_sub "caching the Mendix runtime"
      "$mxcli_now" run --local -p "$APP/$(basename "$APP").mpr" --setup >> "$DEPS_LOG" 2>&1 || true
      ensure_runtime_junction "$want_mx"
    fi
  fi
fi

# Docker, and the alternative to it.
#
# Docker turned out to be needed for far less than the docs used to claim: `mx check`
# runs Mendix's own `mx` from a Studio Pro installation, container or not (verified --
# `mxcli docker check --mxbuild-path <dir>` reports the error count directly). What
# actually wants a container is the database, and a machine with Studio Pro on it
# usually has, or can trivially get, a PostgreSQL instead.
#
# So where Studio Pro is present the no-Docker mode is offered first. It is a real
# mode, written to tests/harness.env, not a degraded fallback.
no_docker_mode=""
if ! docker_ready; then
  studio_dir=""
  if [ -n "${want_mx:-}" ] && [ "$IS_WINDOWS" = "1" ]; then
    studio_mx="$(studio_pro_mx "$want_mx" 2>/dev/null || true)"
    [ -n "$studio_mx" ] && studio_dir="$(cd "$(dirname "$(dirname "$studio_mx")")" && pwd)"
  fi
  # Off Windows the same mode works from a cached or bundled mxbuild.
  if [ -z "$studio_dir" ] && [ -n "${want_mx:-}" ] && [ -d "$HOME/.mxcli/mxbuild/$want_mx" ]; then
    studio_dir="$HOME/.mxcli/mxbuild/$want_mx"
  fi

  interactive=0
  if [ -t 0 ] && [ "$UI_TTY" = 1 ]; then interactive=1; fi
  if [ -n "${MDL_ASSUME_YES:-}" ]; then interactive=1; fi

  # A local mxbuild or Studio Pro is set up whenever one is present, without being
  # asked about: it is what `mx check` runs and what the JDK, Gradle and win-x64
  # repairs attach to, and none of that competes with Docker. Docker is still
  # installed below; this only means the gate does not depend on it for `mx check`.
  if [ -n "$studio_dir" ]; then
    if ! postgres_answers; then
      if psql_path >/dev/null 2>&1; then
        # Installed, but no login answered. Installing it again would not help --
        # ask for a superuser and build the role instead.
        postgres_ask_superuser || true
        if ! postgres_answers; then
          DEPS_MISSING+=("PostgreSQL -- installed, but none of the logins tried could connect.")
          DEPS_MISSING+=("              Put a working one in tests/harness.env and re-run:")
          DEPS_MISSING+=("                MDL_DB_USER=... MDL_DB_PASSWORD=... MDL_DB_HOST=...")
        fi
      else
        dep_need "PostgreSQL" "postgres_answers" \
          "PostgreSQL.PostgreSQL.17" "postgresql@17" "postgresql" || true
      fi
    fi
    ensure_studio_support_junctions "${studio_dir##*/}" "$studio_dir"
    ensure_tool_arch_aliases "$studio_dir"
    write_harness_env "$studio_dir"
    if ! postgres_answers; then
      DEPS_MISSING+=("PostgreSQL -- no login worked yet, so the app cannot boot. Everything")
      DEPS_MISSING+=("              else in the gate runs. Fix the credentials in")
      DEPS_MISSING+=("              tests/harness.env, or create the role by hand:")
      DEPS_MISSING+=("                psql -U postgres -c \"CREATE ROLE ${MDL_DB_USER:-mendix} LOGIN PASSWORD '${MDL_DB_PASSWORD:-mendix}' CREATEDB\"")
    fi
  fi

  # Docker is installed whenever it is missing -- no question asked. It is a
  # prerequisite like Python or Node, not a choice, and it is installed even when a
  # local mxbuild is available, since that only covers `mx check`.
  if have docker; then
    docker_ready || DEPS_MISSING+=("Docker -- installed but the daemon is not running: $(docker_start_command)")
  else
    docker_walkthrough || true
  fi
fi
# The JDK: found rather than demanded. Studio Pro installs one as its own
# prerequisite, and on Windows it is routinely not on the PATH.
want_jdk="$(jdk_major_for "${want_mx:-}")"
found_jdk="$(jdk_find "$want_jdk" || true)"
if [ -z "$found_jdk" ]; then
  dep_report_only "JDK $want_jdk" "false" \
    "EclipseAdoptium.Temurin.$want_jdk.JDK" "temurin@$want_jdk" "temurin-$want_jdk-jdk" || true
elif ! have java || [ "$(java_major java 2>/dev/null)" != "$want_jdk" ]; then
  DEPS_MISSING+=("JDK $want_jdk -- installed but not on the PATH: $found_jdk")
  DEPS_MISSING+=("           \`./mxcli$EXE run --local\` needs it there. In Git Bash:")
  DEPS_MISSING+=("           export PATH=\"\$(dirname '$found_jdk'):\$PATH\"")
fi

if [ "$DEPS_INSTALLED" -gt 0 ]; then
  ui_done "prerequisites" "$DEPS_INSTALLED installed, ${#DEPS_MISSING[@]} still missing"
elif [ "${#DEPS_MISSING[@]}" -gt 0 ]; then
  ui_done "prerequisites" "${#DEPS_MISSING[@]} missing $I_ARROW listed below"
else
  ui_done "prerequisites" "all present"
fi

if [ "$mpr_count" = "0" ]; then
  # The binary is the project's own by convention, but there is no project yet, so
  # take whichever mxcli exists: this app's, one on the PATH, or the installer's.
  new_mxcli=""
  for candidate in "$APP/mxcli$EXE" "$(command -v "mxcli$EXE" 2>/dev/null || true)" \
                   "$SRC/../mxcli$EXE" "$SRC/mxcli$EXE"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { new_mxcli="$candidate"; break; }
  done
  if [ -z "$new_mxcli" ]; then
    ui_fail "No .mpr here, and no mxcli to create one with." \
            "Looked in the project, on the PATH, and beside this installer." \
            "Install mxcli, or point this at an existing Mendix project."
  fi
  # A Mendix app name is not a directory name: keep letters and digits, start with a letter.
  app_name="${APP_NAME:-$(basename "$APP" | sed 's/[^A-Za-z0-9]//g')}"
  case "$app_name" in [A-Za-z]*) ;; *) app_name="App$app_name" ;; esac
  # On Windows the version is not a free choice: `mxcli new` shells out to Studio
  # Pro's mx.exe, and asking for a version it cannot build produces a project
  # silently stamped with Studio Pro's own version instead. So follow the newest
  # Studio Pro that is here, unless MX_VERSION says otherwise.
  if [ -n "${MX_VERSION:-}" ]; then
    mx_version="$MX_VERSION"
  elif [ "$IS_WINDOWS" = "1" ]; then
    mx_version="$(studio_pro_versions | tail -1)"
    if [ -z "$mx_version" ]; then
      ui_fail "No Mendix Studio Pro found, and Windows has no other way to create an app." \
              "mxcli shells out to Studio Pro's mx.exe; the Mendix CDN's mxbuild is Linux-only." \
              "Install Studio Pro, or point this at a project that already has a .mpr."
    fi
  else
    mx_version="11.12.1"
  fi
  # `mxcli new` searches only C:\Program Files\Mendix and has no --mxbuild-path, so a
  # Studio Pro in the per-user directory is invisible to it: it falls back to whatever
  # is in Program Files and stamps the project with that version. Observed on Windows
  # 11 -- asked for 11.12.1 and got 9.24.37.77045, after a long build.
  #
  # Rather than ask for an mklink, drive Studio Pro's own mx.exe. It takes --app-name
  # and --output-dir, defaults to the Blank template, and stamps the version correctly
  # (verified: a project created this way reports 11.12.1). `mxcli init` then does the
  # rest of what `mxcli new` would have done.
  direct_mx=""
  if [ "$IS_WINDOWS" = "1" ] && ! studio_pro_mx_visible_to_mxcli "$mx_version" >/dev/null; then
    direct_mx="$(studio_pro_mx "$mx_version" 2>/dev/null || true)"
    # Creating the app can route around mxcli's blind spot by calling mx.exe, but
    # `mxcli run --local` cannot: it resolves mxbuild itself, looks only in
    # C:\Program Files\Mendix, has no --mxbuild-path, and ignores its own cache
    # directory on Windows (all three verified). A directory junction is the only
    # thing that makes the per-user install visible to it -- so offer to make one,
    # rather than leaving the app unbootable or printing homework.
    [ -n "$direct_mx" ] && offer_studio_pro_junction "$mx_version" "$direct_mx"
  fi

  ui_begin "creating $app_name (Mendix $mx_version)"
  # --theme none / --layout none: stock Atlas. mxcli's own theme follows the OS colour
  # scheme, so on a Mac in dark mode a fresh app renders dark and looks nothing like a
  # standard Mendix app.
  # `mxcli new` refuses a non-empty --output-dir, and the usual target is not empty:
  # an mxcli scaffold already holds CLAUDE.md, .claude/ and .ai-context/. Create the
  # app in a temporary directory and move it in, so the existing files survive and a
  # failed creation leaves nothing behind.
  tmp_app="$(mktemp -d "${TMPDIR:-/tmp}/mdl-skills-new.XXXXXX")"
  trap 'rm -rf "$tmp_app"' EXIT
  # The binary about to run is very often $APP/mxcli.exe -- the same path the
  # scaffold copy below writes over. On Windows a running .exe is locked, and the
  # copy does not fail loudly: it unlinks the target and then cannot write it, so
  # the binary simply disappears. Observed on Windows 11. Keep a copy aside, and
  # do the swap from that.
  stash_mxcli="$tmp_app/mxcli-host$EXE"
  cp "$new_mxcli" "$stash_mxcli" 2>/dev/null || stash_mxcli="$new_mxcli"
  # mxcli prints "Executing step '<phase>'" as it goes. Those phases are the only
  # honest progress available inside a step that runs for a minute or more, so they
  # drive the sub-progress and the log is kept for the failure message.
  if [ -n "$direct_mx" ]; then
    ui_sub "Studio Pro $mx_version (mxcli cannot see this install)"
    if ! "$direct_mx" create-project --app-name "$app_name" --output-dir "$tmp_app/app" \
         >> "$tmp_app/new.log" 2>&1; then
      ui_clear
      printf '  %s%s%s %slast lines of mx create-project:%s\n' "$C_RED" "$I_FAIL" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
      tail -5 "$tmp_app/new.log" 2>/dev/null | sed 's/^/    /' >&2
      ui_fail "Creating the Mendix app failed." \
              "Run it by hand to see why:" \
              "  \"$direct_mx\" create-project --app-name $app_name --output-dir /tmp/probe"
    fi
    ui_tick
    # mxcli new also initialises the AI tooling; do that half separately.
    "$new_mxcli" init "$tmp_app/app" >> "$tmp_app/new.log" 2>&1 || true
    ui_tick
  elif ! "$new_mxcli" new "$app_name" --version "$mx_version" --output-dir "$tmp_app/app" \
       --theme none --layout none 2>&1 | while IFS= read -r line; do
         printf '%s\n' "$line" >> "$tmp_app/new.log"
         case "$line" in
           "Executing step "*) phase="${line#Executing step \'}"; ui_sub "${phase%\'}" ;;
           *...)               ui_tick ;;
         esac
       done; then
    ui_clear
    printf '  %s%s%s %slast lines of mxcli new:%s\n' "$C_RED" "$I_FAIL" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
    tail -5 "$tmp_app/new.log" 2>/dev/null | sed 's/^/    /' >&2
    ui_fail "Creating the Mendix app failed." \
            "Run it by hand to see why:" \
            "  $new_mxcli new $app_name --version $mx_version --output-dir /tmp/probe"
  fi
  # The scaffold's own mxcli is dealt with by the swap below, and copying it over a
  # running one is what breaks; leave it in the temp tree.
  if [ -f "$tmp_app/app/mxcli" ]; then mv "$tmp_app/app/mxcli" "$tmp_app/app-mxcli-linux"; fi
  rm -f "$tmp_app/app/mxcli$EXE" 2>/dev/null || true
  cp -R "$tmp_app/app/." "$APP/"
  # `mxcli new` leaves a Linux mxcli in the app (it is built for the devcontainer), so
  # off Linux the app's own ./mxcli cannot run -- and every script here calls it.
  # `file` is not installed with a minimal Git for Windows, so the ELF test is only
  # asked for where it can be answered; on Windows the swap is unconditional,
  # because a Linux binary there is never the right one.
  if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    # On Linux the scaffold's binary is the right one; put it back where it belongs.
    if [ -f "$tmp_app/app-mxcli-linux" ]; then
      mv "$tmp_app/app-mxcli-linux" "$APP/mxcli"
      chmod +x "$APP/mxcli" 2>/dev/null || true
    fi
  else
    # Off Linux it is kept beside the working binary: the devcontainer wants it.
    if [ -f "$tmp_app/app-mxcli-linux" ]; then
      mv "$tmp_app/app-mxcli-linux" "$APP/mxcli.linux"
    fi
    cp "$stash_mxcli" "$APP/mxcli$EXE" 2>/dev/null || true
    chmod +x "$APP/mxcli$EXE" 2>/dev/null || true
    [ -f "$APP/mxcli.linux" ] && swapped_mxcli=1
  fi
  rm -rf "$tmp_app"
  trap - EXIT
  created_app="$app_name.mpr"
  ui_done "Mendix app created" "$created_app"
  [ -n "${swapped_mxcli:-}" ] && ui_note "./mxcli$EXE swapped for this machine's binary (Linux one kept as mxcli.linux)"
fi

SKILL_DIRS=(.claude/skills .agents/skills .ai-context/skills)

ui_begin "installing skills"
installed_skills=0
for skill in "$SRC"/skills/*/; do
  name="$(basename "$skill")"
  for dest in "${SKILL_DIRS[@]}"; do
    mkdir -p "$APP/$dest/$name"
    cp "$skill/SKILL.md" "$APP/$dest/$name/SKILL.md"
  done
  installed_skills=$((installed_skills + 1))
done
ui_done "skills" "$installed_skills $I_ARROW each of ${SKILL_DIRS[*]}"

ui_begin "installing lint rules"
mkdir -p "$APP/.claude/lint-rules"
cp "$SRC"/lint-rules/*.star "$APP/.claude/lint-rules/"
rules=$(ls -1 "$SRC"/lint-rules/*.star | wc -l | tr -d ' ')
ui_done "lint rules" "$rules $I_ARROW .claude/lint-rules/"

ui_begin "installing checkers"
mkdir -p "$APP/tools/mdl-checks"
cp -R "$SRC"/checks/. "$APP/tools/mdl-checks/"
cp "$SRC/VERSION" "$APP/tools/mdl-checks/VERSION"
checks=$(ls -1 "$SRC"/checks/*.py | wc -l | tr -d ' ')
ui_done "checkers" "$checks $I_ARROW tools/mdl-checks/"

# The always-loaded rule. Lives in .claude/rules/ because mxcli init regenerates
# CLAUDE.md and would drop anything written there; it leaves .claude/rules/ alone.
ui_begin "installing the session rule"
mkdir -p "$APP/.claude/rules"
cp "$SRC/rules/mdl-skills.md" "$APP/.claude/rules/mdl-skills.md"
ui_done "session rule" "1 $I_ARROW .claude/rules/mdl-skills.md"

# Hooks: the scripts are shared (tools/), the registration is per developer in
# .claude/settings.local.json -- the one settings file mxcli init does not
# overwrite. Merged, not replaced, so a developer's own local settings survive.
ui_begin "registering Claude hooks"
mkdir -p "$APP/tools/mdl-checks/hooks"
cp "$SRC"/hooks/*.sh "$APP/tools/mdl-checks/hooks/"
chmod +x "$APP/tools/mdl-checks/hooks/"*.sh
"$PY" - "$APP/.claude/settings.local.json" <<'PY_MERGE'
import json, sys
path = sys.argv[1]
try:
    settings = json.load(open(path))
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}
hooks = settings.setdefault("hooks", {})
wanted = {
    "UserPromptSubmit": {"hooks": [{"type": "command", "command": "bash tools/mdl-checks/hooks/remind-skills.sh"}]},
    "PostToolUse": {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash tools/mdl-checks/hooks/after-mxcli-exec.sh"}]},
}
for event, entry in wanted.items():
    existing = hooks.setdefault(event, [])
    if not any(json.dumps(e, sort_keys=True) == json.dumps(entry, sort_keys=True) for e in existing):
        existing.append(entry)
json.dump(settings, open(path, "w"), indent=2)
PY_MERGE
ui_done "Claude hooks" "2 $I_ARROW .claude/settings.local.json"

# Codex discovers repository skills in .agents/skills automatically. Its hook
# wire format is close to Claude's, but PostToolUse ignores plain stdout, so it
# gets a small adapter while Claude keeps the existing script unchanged. Merge
# rather than replace so a project's existing Codex hooks survive installation.
ui_begin "registering Codex hooks"
mkdir -p "$APP/.codex"

# Hook trust is intentionally separate from project trust. An untrusted hook
# cannot remind the user to trust itself, so inject one first-turn reminder from
# project config instead. Prepend only when the project has no existing
# developer_instructions; never replace a project's own instruction block.
codex_reminder="$("$PY" - "$APP/.codex/config.toml" <<'PY_CODEX_CONFIG'
import os, re, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        existing = handle.read()
except FileNotFoundError:
    existing = ""

if re.search(r"(?m)^[ \t]*developer_instructions[ \t]*=", existing):
    print("existing")
    raise SystemExit(0)

reminder = '''# Codex hook trust reminder
developer_instructions = """
After the first user prompt in each new Codex session for this repository, include one short reminder to open `/hooks` and review or trust the project hooks if they are new or changed. Do not repeat the reminder later in the same session.
"""

'''
with open(path, "w", encoding="utf-8") as handle:
    handle.write(reminder)
    handle.write(existing)
print("added")
PY_CODEX_CONFIG
)"

"$PY" - "$APP/.codex/hooks.json" <<'PY_CODEX_MERGE'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path) as handle:
            settings = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SystemExit("invalid existing %s: %s" % (path, exc))
else:
    settings = {}

settings.setdefault("description", "Mendix MDL skills and delivery gates")
hooks = settings.setdefault("hooks", {})
# A project-relative path, like Claude's and Cursor's. The `$(git rev-parse ...)`
# this used to embed only expands if the host runs hook commands through a POSIX
# shell -- under a native Windows Codex it is literal text. All three scripts
# resolve the repo root themselves anyway.
root = 'tools/mdl-checks/hooks'
wanted = {
    "UserPromptSubmit": {
        "hooks": [{
            "type": "command",
            "command": 'bash %s/remind-skills-codex.sh' % root,
            "timeout": 60,
        }],
    },
    "PostToolUse": {
        "matcher": "^Bash$",
        "hooks": [{
            "type": "command",
            "command": 'bash %s/after-mxcli-exec-codex.sh' % root,
            "timeout": 120,
        }],
    },
    "Stop": {
        "hooks": [{
            "type": "command",
            "command": 'bash %s/stop-gate-codex.sh' % root,
            "timeout": 600,
        }],
    },
}
for event, entry in wanted.items():
    existing = hooks.setdefault(event, [])
    # An earlier install registered the same script through an embedded
    # `$(git rev-parse ...)`. Drop any registration of this script before adding the
    # new one, so an upgrade replaces it instead of firing the hook twice.
    script = entry["hooks"][0]["command"].rsplit("/", 1)[-1].rstrip('"')
    existing[:] = [
        candidate for candidate in existing
        if not any(
            str(handler.get("command", "")).rstrip('"').endswith(script)
            for handler in candidate.get("hooks", [])
        )
    ]
    existing.append(entry)

with open(path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
PY_CODEX_MERGE
ui_done "Codex hooks" "3 $I_ARROW .codex/hooks.json"

# The harness only -- lib.sh, gate.sh, orient.sh, diagnose.sh. The verify-*.test.sh
# scripts are the app's own and are written by whoever builds the feature: shipping
# one app's tests into another project means every full gate fails on entities that
# do not exist there, which is what happened before this changed. Worked examples
# live in the bundle under examples/, and are not installed.
#
# cp -n, so an app that already has these -- or has evolved its own -- keeps them.
# Cursor reads neither .claude/rules/ nor .ai-context/skills/, so the same rules are
# installed in its own shape: an alwaysApply .mdc rule, and three hooks. Its wire
# format differs from both other hosts -- beforeSubmitPrompt cannot inject context
# (only sessionStart can), afterShellExecution cannot answer the agent (only
# postToolUse can), and Stop asks for a follow-up message rather than exiting 2 --
# so it gets its own three adapters over the same shared scripts.
ui_begin "registering Cursor hooks"
mkdir -p "$APP/.cursor/rules"
cp "$SRC/rules/mdl-skills.mdc" "$APP/.cursor/rules/mdl-skills.mdc"

"$PY" - "$APP/.cursor/hooks.json" <<'PY_CURSOR_MERGE'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path) as handle:
            settings = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SystemExit("invalid existing %s: %s" % (path, exc))
else:
    settings = {}

settings.setdefault("version", 1)
hooks = settings.setdefault("hooks", {})
# `bash <path>`, not `./<path>`: on Windows a .sh file is not executable, and the
# shebang means nothing to the shell Cursor spawns.
root = "tools/mdl-checks/hooks"
wanted = {
    "sessionStart": {"command": "bash %s/remind-skills-cursor.sh" % root, "timeout": 30},
    "postToolUse": {"command": "bash %s/after-mxcli-exec-cursor.sh" % root, "timeout": 120},
    # loop_limit caps the auto-submitted follow-ups; the marker is cleared on green,
    # so a session that fixes its failures stops looping before reaching it.
    "stop": {"command": "bash %s/stop-gate-cursor.sh" % root, "timeout": 600, "loop_limit": 5},
}
for event, entry in wanted.items():
    existing = hooks.setdefault(event, [])
    # An earlier install registered the same script as `./tools/...`, which does not
    # run on Windows. Drop any registration of this script before adding the new one,
    # so the upgrade replaces it instead of firing the hook twice.
    script = entry["command"].rsplit("/", 1)[-1]
    existing[:] = [
        candidate for candidate in existing
        if not str(candidate.get("command", "")).endswith(script)
    ]
    existing.append(entry)

with open(path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
PY_CURSOR_MERGE
ui_done "Cursor hooks" "3 $I_ARROW .cursor/hooks.json, 1 rule $I_ARROW .cursor/rules/"

# OpenCode: one plugin does all three jobs. It has no exit-code contract and no
# followup field -- instead its hook payloads are mutable (the text the model reads
# can be appended to) and its SDK client can submit a message into the session.
# Rules come from opencode.json's "instructions" glob rather than AGENTS.md, which
# mxcli regenerates. Both .opencode/plugin/ and .opencode/plugins/ are accepted by
# opencode; the singular is used here.
ui_begin "installing the OpenCode plugin"
mkdir -p "$APP/.opencode/plugin"
cp "$SRC"/plugins/*.js "$APP/.opencode/plugin/"

"$PY" - "$APP/opencode.json" <<'PY_OPENCODE'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path) as handle:
            config = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SystemExit("invalid existing %s: %s" % (path, exc))
else:
    config = {}

config.setdefault("$schema", "https://opencode.ai/config.json")
instructions = config.setdefault("instructions", [])
for entry in (".claude/rules/mdl-skills.md",):
    if entry not in instructions:
        instructions.append(entry)

with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY_OPENCODE
ui_done "OpenCode plugin" "1 $I_ARROW .opencode/plugin/, rules $I_ARROW opencode.json"

ui_begin "installing the test harness"
mkdir -p "$APP/tests"
suite_written=0
for source_file in "$SRC"/tests/*; do
  name="$(basename "$source_file")"
  target="$APP/tests/$name"
  case "$name" in
    # The harness itself is the bundle's, and it is upgraded in place -- a fix in
    # gate.sh that never reaches an installed project is not a fix.
    gate.sh|orient.sh|diagnose.sh|lib.sh|portable.sh) ;;
    # Everything else -- verify-*.test.sh, credentials.env -- belongs to the project.
    *) if [ -e "$target" ]; then continue; fi ;;
  esac
  cp "$source_file" "$target"
  chmod +x "$target" 2>/dev/null || true
  suite_written=$((suite_written + 1))
done

# CRLF is not a line ending to bash: one Windows editor save of gate.sh otherwise
# makes every line fail with `$'\r': command not found`.
if [ ! -e "$APP/.gitattributes" ] && [ -f "$SRC/.gitattributes" ]; then
  cp "$SRC/.gitattributes" "$APP/.gitattributes"
fi
ui_done "test harness" "$suite_written $I_ARROW tests/  (verify-*.test.sh left alone)"

ui_begin "checking the environment"

# `mxcli new` writes .playwright/cli.config.json pinning chromium to a path that may
# not exist on this machine (observed: /usr/local/bin/mx-headless-shell). Every
# browser test then fails with "Error: opening browser: exit status 1", which reads
# like a broken suite rather than a missing binary. Repair it here, once.
playwright_config="$APP/.playwright/cli.config.json"
browser_fixed=""
if [ -f "$playwright_config" ]; then
  browser_fixed="$("$PY" - "$playwright_config" <<'PY_BROWSER'
import glob, json, os, sys

path = sys.argv[1]
try:
    config = json.load(open(path))
except Exception:
    sys.exit(0)
options = config.get("browser", {}).get("launchOptions", {})
current = options.get("executablePath")
if not current or os.path.exists(current):
    sys.exit(0)
# Prefer a headless shell Playwright has already downloaded; otherwise let it choose.
roots = [
    os.path.expanduser("~/Library/Caches/ms-playwright"),   # macOS
    os.path.expanduser("~/.cache/ms-playwright"),           # Linux
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "ms-playwright"),  # Windows
]
candidates = []
for root in roots:
    if not root:
        continue
    for suffix in ("chrome-headless-shell", "chrome-headless-shell.exe"):
        candidates += sorted(glob.glob(os.path.join(
            root, "chromium_headless_shell-*", "chrome-headless-shell-*", suffix)))
if candidates:
    options["executablePath"] = candidates[-1]
    replacement = candidates[-1]
else:
    options.pop("executablePath", None)
    replacement = "Playwright's own browser"
json.dump(config, open(path, "w"), indent=2)
print("%s -> %s" % (current, replacement))
PY_BROWSER
)"
fi

# `mx check` needs mxbuild for the project's own Mendix version. Missing, it surfaces
# halfway through a gate as a check that "did not report a count" -- a machine problem
# wearing the costume of a model problem. The version lives in the .mpr, which is a
# SQLite file, so this costs milliseconds and needs no runtime.
mxbuild_note=""
mxbuild_note="$("$PY" - "$APP" "$IS_WINDOWS" <<'PY_MXBUILD'
import glob, os, sqlite3, sys

app = sys.argv[1]
mprs = glob.glob(os.path.join(app, "*.mpr"))
if not mprs:
    sys.exit(0)
try:
    con = sqlite3.connect("file:%s?mode=ro" % mprs[0], uri=True)
    version = con.execute("select * from _MetaData limit 1").fetchone()[1]
except Exception:
    sys.exit(0)
cached = os.path.expanduser("~/.mxcli/mxbuild/%s" % version)
if sys.argv[2] == "1":
    # Studio Pro installs in two places; 10.x and 11.x default to the per-user one.
    roots = [os.path.join(os.environ.get("ProgramFiles", "C:\\Program Files"), "Mendix"),
             os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Mendix")]
    cached = ""
    for root in roots:
        if not root:
            continue
        candidate = os.path.join(root, version, "modeler")
        if os.path.isdir(candidate):
            cached = candidate
            break
    cached = cached or os.path.join(roots[0], version, "modeler")
if not os.path.isdir(cached):
    if os.name == "nt" or sys.argv[2] == "1":
        print("Mendix %s: `mx check` needs Studio Pro %s -- the Mendix CDN's mxbuild is "
              "Linux-only, so `mxcli setup mxbuild` cannot help here." % (version, version))
    else:
        print("Mendix %s, no mxbuild cached -- `mx check` will not run until: "
              "./mxcli setup mxbuild -p %s" % (version, os.path.basename(mprs[0])))
PY_MXBUILD
)"

rules=${rules:-$(ls -1 "$SRC"/lint-rules/*.star | wc -l | tr -d ' ')}
checks=${checks:-$(ls -1 "$SRC"/checks/*.py | wc -l | tr -d ' ')}

ui_done "environment" "checked"

# ---------------------------------------------------------------------------
# Summary. One block, aligned, so the reader can see what landed without
# re-reading the scroll of steps above.
# ---------------------------------------------------------------------------
ui_clear
printf '\n  %s%s Installed mendix-mdl-skills %s%s\n' "$C_GREEN" "$I_OK" "$version" "$C_RESET"
printf '  %s  %s %s%s\n' "$C_GREY" "$I_ARROW" "$APP" "$C_RESET"

ui_head "$I_BOX" "What landed"
if [ -n "${created_app:-}" ]; then
  ui_row "app" "1" "$created_app  ${C_GREY}(created empty, Mendix ${mx_version:-?})${C_RESET}"
fi
ui_row "skills"   "$installed_skills" ".claude/skills  .agents/skills  .ai-context/skills"
ui_row "lint"     "$rules"            ".claude/lint-rules/"
ui_row "checkers" "$checks"           "tools/mdl-checks/  ${C_GREY}(VERSION $version)${C_RESET}"
ui_row "rule"     "1"                 ".claude/rules/mdl-skills.md  ${C_GREY}(every session)${C_RESET}"
ui_row "hooks"    "2"                 ".claude/settings.local.json  ${C_GREY}(Claude)${C_RESET}"
ui_row "hooks"    "3"                 ".codex/hooks.json  ${C_GREY}(Codex)${C_RESET}"
ui_row "hooks"    "3"                 ".cursor/hooks.json  ${C_GREY}(Cursor, + .cursor/rules/)${C_RESET}"
ui_row "plugin"   "1"                 ".opencode/plugin/  ${C_GREY}(OpenCode, + opencode.json)${C_RESET}"
if [ "$codex_reminder" = "added" ]; then
  ui_row "reminder" "1"               ".codex/config.toml  ${C_GREY}(after the first prompt)${C_RESET}"
else
  printf '     %s%-10s%s %s%3s%s  %s\n' "$C_YELLOW" "reminder" "$C_RESET" "$C_BOLD" "$I_WARN" "$C_RESET" \
    ".codex/config.toml already defines developer_instructions, left alone"
fi
if [ "$suite_written" -gt 0 ]; then
  ui_row "harness" "$suite_written"   "tests/  ${C_GREY}(verify-*.test.sh are yours to write)${C_RESET}"
else
  ui_row "harness" "0"                "tests/ already had them, nothing overwritten"
fi
if [ -n "$browser_fixed" ]; then
  ui_row "repaired" "1"               ".playwright/cli.config.json  ${C_GREY}browser path${C_RESET}"
fi
if [ "$DEPS_INSTALLED" -gt 0 ]; then
  ui_row "deps"     "$DEPS_INSTALLED" "prerequisites installed  ${C_GREY}(log: $DEPS_LOG)${C_RESET}"
fi
if [ -n "${no_docker_mode:-}" ]; then
  ui_row "mx check" "1"               "local  ${C_GREY}($no_docker_mode + PostgreSQL, tests/harness.env)${C_RESET}"
fi

if [ -n "$mxbuild_note" ]; then
  printf '\n  %s%s%s %s\n' "$C_YELLOW" "$I_WARN" "$C_RESET" "$mxbuild_note"
fi

# The tools that are still missing, each with the command that fixes it. Held to
# the end on purpose: it is the last thing on screen, which is where someone
# looks when the next command fails.
if [ "${#DEPS_MISSING[@]}" -gt 0 ]; then
  printf '\n  %s%s Still missing%s\n' "$C_BOLD" "$I_WARN" "$C_RESET"
  for line in "${DEPS_MISSING[@]}"; do
    printf '     %s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
  done
  if [ "$WITH_DEPS" = "0" ]; then
    printf '     %s%s%s\n' "$C_GREY" "re-run with --with-deps to have these installed for you" "$C_RESET"
  fi
fi

ui_head "$I_PLAY" "Next"
printf '     %-38s %s%s%s\n' "bash tests/orient.sh" "$C_GREY" "what is in this app, and its state" "$C_RESET"
printf '     %-38s %s%s%s\n' "bash tests/gate.sh --boot-if-needed" "$C_GREY" "suite + mx check + lint + coverage" "$C_RESET"
printf '     %-38s %s%s%s\n' "bash tests/gate.sh --only <feature>" "$C_GREY" "one script, warm browser, red loop" "$C_RESET"
printf '     %-38s %s%s%s\n' "bash tests/diagnose.sh <Entity> <user>" "$C_GREY" "why is that row not on the page" "$C_RESET"

ui_head "$I_DOT" "Good to know"
printf '     %s\n' "Codex will not fire its hooks until you open ${C_BOLD}/hooks${C_RESET} once and trust them."
printf '     %s\n' "Cursor needs hooks enabled for this workspace before ${C_BOLD}.cursor/hooks.json${C_RESET} runs."
printf '     %s\n' "OpenCode loads ${C_BOLD}.opencode/plugin/${C_RESET} at startup; restart an open session to pick it up."
printf '     %s\n' "Write your own tests/verify-<feature>.test.sh -- the ${C_BOLD}test-first-delivery${C_RESET} skill has a"
printf '     %s\n' "complete example, and $SRC/examples/ holds eight from the demo app."
printf '\n'
