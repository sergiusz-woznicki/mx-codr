#!/usr/bin/env bash
# run-app.sh -- boot the app without `mxcli run --local` (which cannot boot on Windows):
# mxbuild deployment, standalone runtime, M2EE admin API. Run by gate.sh --boot-if-needed
# (MDL_BOOT_COMMAND in tests/harness.env) or by hand. Settings from tests/harness.env.
#   bash tests/run-app.sh [--rebuild]    (rebuilds anyway when the .mpr is newer)
# Prints "== step" lines; exit 0 with "== app up on ...", exit 1 with "== start FAILED".
set -euo pipefail

# --- 1. Paths and settings ---
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"
# harness.env is read as data, not sourced (see tests/portable.sh).
. "$APP_DIR/tests/portable.sh"
mdl_load_harness_env "$APP_DIR/tests/harness.env" export

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE_SUFFIX=".exe" ;; *) EXE_SUFFIX="" ;; esac

# All paths derived from the Mendix version and harness.env; override in the environment.
MPR="$(ls -1 "$APP_DIR"/*.mpr | head -1)"
MX_VERSION="${MX_VERSION:-$(basename "${MDL_MXBUILD_PATH:-}")}"
if [ -z "$MX_VERSION" ] || [ ! -d "$HOME/.mxcli/mxbuild/$MX_VERSION" ]; then
  for _d in "$HOME"/.mxcli/mxbuild/*/; do [ -d "$_d" ] && MX_VERSION="$(basename "$_d")"; done
fi
MXCACHE="${MXCACHE:-$HOME/.mxcli/mxbuild/$MX_VERSION}"
MXBUILD="${MXBUILD:-$MXCACHE/modeler/mxbuild$EXE_SUFFIX}"
MXBUILD_TOOLS="${MXBUILD_TOOLS:-$MXCACHE/modeler/tools/node}"
RUNTIME="${RUNTIME:-$HOME/.mxcli/runtime/$MX_VERSION}"
# JAVA_HOME must be space-free: mxbuild splits its arguments on spaces.
JAVA_DIR="${JAVA_HOME:-}"
JAVA="${JAVA:-$JAVA_DIR/bin/java$EXE_SUFFIX}"
GRADLE_HOME="${GRADLE_HOME:-$MXCACHE/gradle-8.5}"
[ -d "$GRADLE_HOME" ] || GRADLE_HOME="${MDL_MXBUILD_PATH:-}/gradle-8.5"
APP_PORT="${APP_PORT:-8081}"
ADMIN_PORT="${ADMIN_PORT:-8090}"
# mxcli oql and diagnose.sh use this password by default.
ADMIN_PASS="${ADMIN_PASSWORD:-${ADMIN_PASS:-mxcli-local-dev}}"
DB_HOST="${MDL_DB_HOST:-127.0.0.1:5432}"
DB_NAME="${MDL_DB_NAME:-$(basename "$MPR" .mpr | tr '[:upper:]' '[:lower:]')}"
DB_USER="${MDL_DB_USER:-mendix}"
DB_PASSWORD="${MDL_DB_PASSWORD:-mendix}"
PY="${PY:-$(mdl_find_python)}"

# admin <json-body> -- send one M2EE admin action, print the JSON answer.
admin() {                                   # admin <json-body>
  curl -s -m 300 -H "X-M2EE-Authentication: $(printf '%s' "$ADMIN_PASS" | base64)" \
    -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$ADMIN_PORT/"
}

# Kill every Mendix runtime java process (Windows/PowerShell).
stop_runtime() {
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" | Where-Object { \$_.CommandLine -like '*runtimelauncher*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1 || true
  sleep 2
}

# needs_rebuild [--rebuild] -- true when asked or the .mpr is newer than the built deployment (no hot reload).
needs_rebuild() {
  [ "${1:-}" = "--rebuild" ] && return 0
  [ -f "$APP_DIR/deployment/model/model.mdp" ] || return 0
  [ "$MPR" -nt "$APP_DIR/deployment/model/model.mdp" ]
}

# --- 2. Build the deployment ---
if needs_rebuild "${1:-}"; then
  echo "== building deployment (this is the slow part)"
  stop_runtime
  # --target=deploy cleans deployment/ and can corrupt Studio Pro's HSQLDB there: save and restore it.
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

# --- 3. Point the built configuration at PostgreSQL ---
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

# --- 4. Bundle the web client ---
# mxbuild never runs rollup; without dist/index.js the app renders a blank page.
if [ ! -f "$APP_DIR/deployment/web/dist/index.js" ] \
   || [ "$APP_DIR/deployment/web/index.js" -nt "$APP_DIR/deployment/web/dist/index.js" ]; then
  echo "== bundling the web client (mxbuild skips this)"
  # Use whichever bundled node exists (ARM Studio Pro ships win-arm64 only).
  NODE=""
  for _a in win-x64 win-arm64 linux-x64 darwin-arm64; do
    [ -x "$MXBUILD_TOOLS/$_a/node$EXE_SUFFIX" ] && { NODE="$MXBUILD_TOOLS/$_a/node$EXE_SUFFIX"; break; }
  done
  [ -n "$NODE" ] || { echo "no bundled node under $MXBUILD_TOOLS" >&2; exit 1; }
  ( cd "$APP_DIR/deployment/web" && NODE_ENV=production "$NODE" \
      "$MXBUILD_TOOLS/node_modules/rollup/dist/bin/rollup" -c rollup.config.mjs 2>&1 | tail -2 )
fi

# --- 5. Start the runtime ---
echo "== starting the runtime container"
stop_runtime
# studiopro=true registers the /dev/ servlets `mxcli oql` needs.
MX_INSTALL_PATH="$RUNTIME" M2EE_ADMIN_PASS="$ADMIN_PASS" M2EE_ADMIN_PORT="$ADMIN_PORT" \
  nohup "$JAVA" -Dmendix.running.locally.by.studiopro=true \
  -jar "$RUNTIME/runtime/launcher/runtimelauncher.jar" \
  "$(cygpath -w "$APP_DIR/deployment" 2>/dev/null || echo "$APP_DIR/deployment")" \
  > "$APP_DIR/.mxcli/runtime.log" 2>&1 &

for _ in $(seq 1 90); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$ADMIN_PORT/" && break
  sleep 1
done

# --- 6. Configure and start through the admin API ---
# Jetty needs all three params, or `start` fails with "No Runtime Jetty server available".
admin "{\"action\":\"update_appcontainer_configuration\",\"params\":{\"runtime_port\":$APP_PORT,\"runtime_listen_addresses\":\"127.0.0.1\",\"runtime_jetty_options\":{}}}" >/dev/null

# BasePath/RuntimePath have no defaults; json.dumps escapes Windows backslashes.
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
# result 3: schema behind the model -- apply DDL and start again.
case "$result" in
  *'"result":3'*) admin '{"action":"execute_ddl_commands"}' >/dev/null
                  result="$(admin '{"action":"start"}')" ;;
esac

case "$result" in
  *'"result":0'*) echo "== app up on http://localhost:$APP_PORT/" ;;
  *) echo "$result" | head -c 600; echo; echo "== start FAILED" >&2; exit 1 ;;
esac
