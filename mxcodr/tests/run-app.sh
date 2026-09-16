#!/usr/bin/env bash
# Start the app WITHOUT `mxcli run --local`, for machines where that cannot boot.
#
# Why this exists: on Windows, `mxcli run --local` fails in four places before it
# ever reaches the app, none of which it reports.
#   0. On ARM, Studio Pro ships tools/deno and tools/node as win-arm64 only while
#      mxbuild launches win-x64, so `mxbuild --serve` dies with Win32Exception (2).
#      install.sh aliases the directory names.
#   1. mxbuild splits its own command line on spaces, so --java-home="C:\Program
#      Files (Arm)\zulu21" arrives as four unrecognised arguments and it exits
#      printing its usage. install.sh works around this with a space-free junction.
#   2. The mxbuild cache holds only modeler/ and runtime/; Java compilation needs
#      Studio Pro's gradle-8.5 beside them. install.sh junctions it in.
#   3. mxcli's liveness probe is os.Process.Signal(0), which Windows rejects for
#      every signal but Kill -- so a perfectly healthy mxbuild and a perfectly
#      healthy runtime both read as "exited during startup" on the first poll.
#      Only a patched mxcli fixes this (see mxcli-windows-serve-fix.patch).
# Until that patch ships, this does what mxcli would have done anyway: build a
# deployment with mxbuild, boot the standalone runtime, and drive it over the M2EE
# admin API. Slower than the warm loop (a model change needs `--rebuild`, ~1-2 min),
# but it actually runs.
#
#   bash tests/run-app.sh              # boot from the existing deployment
#   bash tests/run-app.sh --rebuild    # rebuild the deployment from the .mpr first
#
# Everything it needs comes from tests/harness.env -- the JDK (JAVA_HOME, which must
# have no spaces), the Studio Pro directory (MDL_MXBUILD_PATH) and the database.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"
# harness.env is read as data, not sourced -- see the note in tests/portable.sh. The
# keys below are the ones this script needs in the environment of mxbuild, java and
# the admin calls; the rest stay shell variables, exactly as before.
. "$APP_DIR/tests/portable.sh"
mdl_load_harness_env "$APP_DIR/tests/harness.env" export

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE_SUFFIX=".exe" ;; *) EXE_SUFFIX="" ;; esac

# Paths are derived, not hardcoded: the cache is keyed by Mendix version and the
# JDK by whatever install.sh found. Override any of them in the environment.
MPR="$(ls -1 "$APP_DIR"/*.mpr | head -1)"
MX_VERSION="${MX_VERSION:-$(basename "${MDL_MXBUILD_PATH:-}")}"
if [ -z "$MX_VERSION" ] || [ ! -d "$HOME/.mxcli/mxbuild/$MX_VERSION" ]; then
  for _d in "$HOME"/.mxcli/mxbuild/*/; do [ -d "$_d" ] && MX_VERSION="$(basename "$_d")"; done
fi
MXCACHE="${MXCACHE:-$HOME/.mxcli/mxbuild/$MX_VERSION}"
MXBUILD="${MXBUILD:-$MXCACHE/modeler/mxbuild$EXE_SUFFIX}"
MXBUILD_TOOLS="${MXBUILD_TOOLS:-$MXCACHE/modeler/tools/node}"
RUNTIME="${RUNTIME:-$HOME/.mxcli/runtime/$MX_VERSION}"
# JAVA_HOME comes from harness.env and is already space-free there; mxbuild is given
# the same one, because it is the argument that breaks when it has spaces.
JAVA_DIR="${JAVA_HOME:-}"
JAVA="${JAVA:-$JAVA_DIR/bin/java$EXE_SUFFIX}"
GRADLE_HOME="${GRADLE_HOME:-$MXCACHE/gradle-8.5}"
[ -d "$GRADLE_HOME" ] || GRADLE_HOME="${MDL_MXBUILD_PATH:-}/gradle-8.5"
APP_PORT="${APP_PORT:-8081}"
ADMIN_PORT="${ADMIN_PORT:-8090}"
# mxcli oql and tests/diagnose.sh authenticate with this exact password by default, so
# the runtime must be started with it or every data assertion fails with
# "OQL error: Authentication failed."
ADMIN_PASS="${ADMIN_PASSWORD:-${ADMIN_PASS:-mxcli-local-dev}}"
DB_HOST="${MDL_DB_HOST:-127.0.0.1:5432}"
DB_NAME="${MDL_DB_NAME:-$(basename "$MPR" .mpr | tr '[:upper:]' '[:lower:]')}"
DB_USER="${MDL_DB_USER:-mendix}"
DB_PASSWORD="${MDL_DB_PASSWORD:-mendix}"
PY="${PY:-$(mdl_find_python)}"

admin() {                                   # admin <json-body>
  curl -s -m 300 -H "X-M2EE-Authentication: $(printf '%s' "$ADMIN_PASS" | base64)" \
    -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$ADMIN_PORT/"
}

stop_runtime() {
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" | Where-Object { \$_.CommandLine -like '*runtimelauncher*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1 || true
  sleep 2
}

# There is no hot reload here: the runtime reads a BUILT deployment, so a model change
# that has not been rebuilt is invisible to it and the suite quietly measures the old
# app. Rebuild whenever the .mpr is newer than what was built, not only when asked.
needs_rebuild() {
  [ "${1:-}" = "--rebuild" ] && return 0
  [ -f "$APP_DIR/deployment/model/model.mdp" ] || return 0
  [ "$MPR" -nt "$APP_DIR/deployment/model/model.mdp" ]
}

if needs_rebuild "${1:-}"; then
  echo "== building deployment (this is the slow part)"
  stop_runtime
  # --target=deploy runs a Clean up step over the whole of deployment/, and Studio
  # Pro's own HSQLDB lives in deployment/data/database/. A build has been seen
  # leaving it half-written -- the version table with no row in it -- after which
  # Studio Pro cannot open the project until the database is thrown away. The
  # runtime here talks to PostgreSQL, so that database is nobody's business but
  # Studio Pro's: copy it out of the way and put it back afterwards.
  SAVED_DB=""
  if [ -d "$APP_DIR/deployment/data/database" ]; then
    SAVED_DB="$(mdl_tmpdir mdl-hsqldb)"
    cp -R "$APP_DIR/deployment/data/database/." "$SAVED_DB/" 2>/dev/null || SAVED_DB=""
  fi
  "$MXBUILD" "--java-home=$JAVA_DIR" "--java-exe-path=$JAVA" \
    "--gradle-home=$GRADLE_HOME" --target=deploy "$MPR" 2>&1 | tail -3
  if [ -n "$SAVED_DB" ]; then
    mkdir -p "$APP_DIR/deployment/data/database"
    cp -R "$SAVED_DB/." "$APP_DIR/deployment/data/database/" 2>/dev/null || true
    rm -rf "$SAVED_DB"
    echo "   (Studio Pro's local database kept across the build)"
  fi
fi

# mxbuild writes the project's own configuration into the deployment, and this
# project is configured for HSQLDB. The runtime here talks to the local Postgres,
# so the built config is repointed rather than the project changed.
"$PY" - "$APP_DIR" "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$APP_PORT" <<'PY'
import json, pathlib, sys
app, host, name, user, password, port = sys.argv[1:7]
p = pathlib.Path(app) / 'deployment' / 'model' / 'config.json'
cfg = json.loads(p.read_text())
cfg['Configuration'].update({
    'DatabaseType': 'PostgreSQL', 'DatabaseHost': host,
    'DatabaseName': name, 'DatabaseUserName': user,
    'DatabasePassword': password,
    'ApplicationRootUrl': 'http://localhost:%s/' % port,
})
p.write_text(json.dumps(cfg, indent=2))
PY

# mxbuild's "Bundle application" step compiles Java and then stops -- it never runs
# rollup, so deployment/web/dist/ is missing and index.html's <script src="dist/index.js">
# 404s. The app boots, serves 200, and renders a blank page: no .mx-page, so every
# browser test times out on a selector rather than saying what is wrong.
# mxbuild has already WRITTEN the bundle inputs (index.js, rollup.config.mjs with
# absolute paths into the cached modeler), so running rollup by hand finishes the job
# in ~3s.
if [ ! -f "$APP_DIR/deployment/web/dist/index.js" ] \
   || [ "$APP_DIR/deployment/web/index.js" -nt "$APP_DIR/deployment/web/dist/index.js" ]; then
  echo "== bundling the web client (mxbuild skips this)"
  # Studio Pro on ARM ships node as win-arm64 only; x64 machines have win-x64. Take
  # whichever is actually there rather than assuming the one mxbuild asks for.
  NODE=""
  for _a in win-x64 win-arm64 linux-x64 darwin-arm64; do
    [ -x "$MXBUILD_TOOLS/$_a/node$EXE_SUFFIX" ] && { NODE="$MXBUILD_TOOLS/$_a/node$EXE_SUFFIX"; break; }
  done
  [ -n "$NODE" ] || { echo "no bundled node under $MXBUILD_TOOLS" >&2; exit 1; }
  ( cd "$APP_DIR/deployment/web" && NODE_ENV=production "$NODE" \
      "$MXBUILD_TOOLS/node_modules/rollup/dist/bin/rollup" -c rollup.config.mjs 2>&1 | tail -2 )
fi

echo "== starting the runtime container"
stop_runtime
# -Dmendix.running.locally.by.studiopro=true registers the /dev/ servlets, including
# preview_execute_oql -- the endpoint `mxcli oql` needs. Without it the runtime answers
# "Action not found" and every await_row/oql_value in the suite fails.
MX_INSTALL_PATH="$RUNTIME" M2EE_ADMIN_PASS="$ADMIN_PASS" M2EE_ADMIN_PORT="$ADMIN_PORT" \
  nohup "$JAVA" -Dmendix.running.locally.by.studiopro=true \
  -jar "$RUNTIME/runtime/launcher/runtimelauncher.jar" \
  "$(cygpath -w "$APP_DIR/deployment" 2>/dev/null || echo "$APP_DIR/deployment")" \
  > "$APP_DIR/.mxcli/runtime.log" 2>&1 &

for _ in $(seq 1 90); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$ADMIN_PORT/" && break
  sleep 1
done

# The Jetty server does not exist until this is called, and it needs all three
# parameters -- runtime_port alone leaves `start` failing with
# "No Runtime Jetty server available".
admin "{\"action\":\"update_appcontainer_configuration\",\"params\":{\"runtime_port\":$APP_PORT,\"runtime_listen_addresses\":\"127.0.0.1\",\"runtime_jetty_options\":{}}}" >/dev/null

# BasePath and RuntimePath have no defaults in the standalone launcher: without
# them `start` fails with "BasePath should be defined" and then
# "Cannot initialize, RuntimePath has no value yet."
# Windows paths carry backslashes, which are JSON escapes -- building this by hand in
# the shell produced an empty BasePath and a bare RuntimeException. json.dumps does the
# escaping correctly.
config_json() {
  "$PY" - "$(cygpath -w "$APP_DIR/deployment")" "$(cygpath -w "$RUNTIME/runtime")" "$APP_PORT" \
        "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" <<'PY'
import json, sys
base, runtime, port, host, name, user, password = sys.argv[1:8]
print(json.dumps({"action": "update_configuration", "params": {
    "BasePath": base,
    "RuntimePath": runtime,
    "DTAPMode": "D",
    "DatabaseType": "PostgreSQL", "DatabaseHost": host,
    "DatabaseName": name,
    "DatabaseUserName": user, "DatabasePassword": password,
    "ApplicationRootUrl": "http://localhost:%s/" % port,
    "MicroflowConstants": {
        "FeedbackModule.LocalStorageKey": "mxfeedback-form-data",
        "FeedbackModule.ClientIdentifier": "Feedback Module 4.0.2"},
}}))
PY
}
admin "$(config_json)" >/dev/null

result="$(admin '{"action":"start"}')"
# result 3 = the database schema is behind the model; apply the DDL and start again.
case "$result" in
  *'"result":3'*) admin '{"action":"execute_ddl_commands"}' >/dev/null
                  result="$(admin '{"action":"start"}')" ;;
esac

case "$result" in
  *'"result":0'*) echo "== app up on http://localhost:$APP_PORT/" ;;
  *) echo "$result" | head -c 600; echo; echo "== start FAILED" >&2; exit 1 ;;
esac
