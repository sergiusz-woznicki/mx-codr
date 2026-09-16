#!/usr/bin/env bash
# lib.sh -- shared helpers for browser tests. A test sources it after its `# covers:` line:
#   source "$(dirname "$0")/lib.sh"
# Rule: ONE scenario per test -- each playwright-cli process costs ~0.6s to start; oql is ~0.03s.
# Exit codes: pass 0, fail() 1, SCRIPT_TIMEOUT 124.
#
# Shell helpers:
#   scenario '<js body>'                 run one browser journey; print its return value as JSON
#   field "$result" <key>                print one value (true/false/null spelled as JSON)
#   fields "$result" <key>...            print several values, one per line
#   oql "<OQL>"                          query the app's database; rows as JSON
#   oql_count <Entity> ["<where>"]       count matching rows of $MODULE.<Entity>
#   oql_value <Entity> <Attr> "<where>"  first match's value ('empty' / 'no-such-row')
#   await_row <Entity> "<where>" [s]     wait up to s seconds (default 8) for a row; 1 if none
#   fail "<message>"                     "FAIL: <message>" on stderr, exit 1
#   release_session                      sign the browser out (gate.sh, end of run)
#
# JS helpers (inside a scenario; 'widget' = Mendix name, i.e. .mx-name-<widget>; `page` = Playwright):
#   open_app()                         open the app, sign in as TEST_USER if asked
#   reopen_app()                       start over (page.goto is refused once the app is open)
#   menu('Label'[, 'widget'])          click a menu item; the widget proves arrival
#   landed('widget', 'what')           throw unless the widget appears
#   fill('widget', value)              type into a text box/area, then tab out
#   pick_combo('widget', 'option')     choose a combo box option
#   row_action('grid', 'text', 'btn')  click a button in the first grid row containing text
#   await_message(/regex/[, ms])       wait for an app message; returns the page text
#   dismiss_dialog()                   click OK on an open dialog
#   page_text()                        all visible page text
#   BASE, USER, PASSWORD, ACTION_TIMEOUT  constants from the settings
#
# Env (all optional):
#   BASE_URL                               app address (default http://localhost:8081)
#   APP_DIR, MPR                           project folder and .mpr (default: folder above tests/)
#   MXCLI, PY                              mxcli and Python (default: tests/portable.sh)
#   TEST_USER, TEST_PASSWORD, CREDENTIALS  sign-in (default: tests/credentials.env)
#   MODULE                                 module for oql_count/oql_value
#   RUNTIME_LOG                            read for licence refusals (default .mxcli/runtime.log)
#   SCRIPT_TIMEOUT                         per-script limit, "90" or "90s"
#   ACTION_TIMEOUT_MS                      wait per browser step (default 8000)
#   KEEP_SESSION, MDL_SESSION_REUSE, FRESH_SESSION  session reuse (section 6)
#   ADMIN_HOST, ADMIN_PORT                 admin API for oql (default localhost:8090)
#
# Sections: 1 Paths  2 Credentials  3 Module  4 fail  5 Time limit  6 Sessions
#           7 scenario  8 field/fields  9 Data assertions

# --- 1. Paths and tools ---
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8081}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MPR="${MPR:-$(cd "$APP_DIR" && ls -1 *.mpr | head -1)}"
# MXCLI and PY come from portable.sh unless already set.
PORTABLE_APP_DIR="$APP_DIR"
. "$(dirname "${BASH_SOURCE[0]}")/portable.sh"

# --- 2. Credentials ---
# From the environment, else tests/credentials.env (TEST_USER=, TEST_PASSWORD=,
# TEST_PASSWORD_<user>=), else none (Security Level: Off).
CREDENTIALS="${CREDENTIALS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/credentials.env}"
if [ -z "${TEST_USER:-}" ] && [ -f "$CREDENTIALS" ]; then
  _user_line="$(grep -E '^TEST_USER=' "$CREDENTIALS" 2>/dev/null | tail -1 || true)"
  TEST_USER="${_user_line#*=}"
fi
TEST_USER="${TEST_USER:-demo_administrator}"
if [ -z "${TEST_PASSWORD:-}" ] && [ -f "$CREDENTIALS" ]; then
  # Read as data, never sourced. -F: TEST_USER is a literal, not a pattern.
  _per_user="$(grep -F -- "TEST_PASSWORD_${TEST_USER}=" "$CREDENTIALS" 2>/dev/null \
    | grep -F -v -e '#' | tail -1 || true)"
  _shared="$(grep -E '^TEST_PASSWORD=' "$CREDENTIALS" 2>/dev/null | tail -1 || true)"
  TEST_PASSWORD="${_per_user#*=}"
  [ -n "$TEST_PASSWORD" ] || TEST_PASSWORD="${_shared#*=}"
  TEST_PASSWORD="${TEST_PASSWORD%\"}"; TEST_PASSWORD="${TEST_PASSWORD#\"}"
fi
TEST_PASSWORD="${TEST_PASSWORD:-}"

# --- 3. Module ---
# gate.sh exports MODULE; otherwise the project's first own module.
if [ -z "${MODULE:-}" ]; then
  MODULE="$("$MXCLI" -p "$APP_DIR/$MPR" --json -c "SHOW MODULES" 2>/dev/null \
    | "$PY" -c 'import json,sys
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for row in rows:
    if not (row.get("Source") or "").strip() and row.get("Module") not in ("System", "MyFirstModule"):
        print(row["Module"]); break' 2>/dev/null)"
fi
# Else the module on the test's `# covers:` line (a red-first test runs before the module exists).
if [ -z "${MODULE:-}" ] && [ -f "${BASH_SOURCE[1]:-}" ]; then
  MODULE="$(sed -nE 's/^#[[:space:]]*covers:[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)\..*/\1/p' \
    "${BASH_SOURCE[1]}" 2>/dev/null | head -1)"
fi

# --- 4. fail and the runtime log ---
RUNTIME_LOG="${RUNTIME_LOG:-$APP_DIR/.mxcli/runtime.log}"

# Inside $(...) fail ends only that subshell; callers add `|| exit 1`.
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 5. Time limit ---
# The runner's SIGKILL leaves playwright-cli running, so each script kills its own tree 5s earlier.
_MDL_LIMIT="${SCRIPT_TIMEOUT:-90}"; _MDL_LIMIT="${_MDL_LIMIT%s}"
case "$_MDL_LIMIT" in ''|*[!0-9]*) _MDL_LIMIT=90 ;; esac
if [ "$_MDL_LIMIT" -gt 15 ]; then _MDL_LIMIT=$((_MDL_LIMIT - 5)); fi

# Print every process under <pid>, deepest first (pgrep, or ps -ef on Git Bash).
_mdl_descendants() {
  local child
  # Skip $BASHPID: the watchdog subshell must not kill itself.
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$1" 2>/dev/null); do
      [ "$child" = "$BASHPID" ] && continue
      _mdl_descendants "$child"; echo "$child"
    done
  else
    for child in $(ps -ef 2>/dev/null | awk -v p="$1" 'NR > 1 && $2 == p {print $1}'); do
      [ "$child" = "$BASHPID" ] && continue
      _mdl_descendants "$child"; echo "$child"
    done
  fi
}
_mdl_kill_tree() {   # _mdl_kill_tree <pid>
  local victims
  victims="$(_mdl_descendants "$1")"
  [ -n "$victims" ] || return 0
  # shellcheck disable=SC2086
  kill -TERM $victims 2>/dev/null || true
  sleep 1
  # shellcheck disable=SC2086
  kill -KILL $victims 2>/dev/null || true
}

# Bash defers a trapped TERM until the foreground command ends, so the watchdog also kills the children.
# The flag file appearing tells the EXIT trap the watchdog fired.
_MDL_TIMEOUT_FLAG="$(mdl_tmpfile mdl-watchdog)"; rm -f "$_MDL_TIMEOUT_FLAG"
_MDL_TIMED_OUT=0
# The timeout report, on stderr; both the TERM and the EXIT handler print it.
_mdl_timeout_message() {
  echo "FAIL: test exceeded ${_MDL_LIMIT}s (SCRIPT_TIMEOUT): a browser call or a polling loop never returned." \
       "If the next test hangs too, the browser is stuck: playwright-cli close && playwright-cli open" >&2
}
# TERM handler: report, kill the children, exit 124.
_mdl_timed_out() {
  _MDL_TIMED_OUT=1
  _mdl_timeout_message
  _mdl_kill_tree $$
  exit 124
}
trap _mdl_timed_out TERM
# Watchdog: sleep, set the flag, TERM the script, kill its process tree.
( trap 'kill $! 2>/dev/null; exit 0' TERM
  sleep "$_MDL_LIMIT" & wait $!
  : > "$_MDL_TIMEOUT_FLAG"
  kill -TERM $$ 2>/dev/null
  _mdl_kill_tree $$ ) 2>/dev/null &
_MDL_WATCHDOG=$!

# _mdl_bounded <seconds> <command...> -- run it, give up after <seconds> (the browser may be hung).
_mdl_bounded() {
  local limit="$1" pid waited=0; shift
  "$@" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((limit * 4)) ]; then kill "$pid" 2>/dev/null; return 1; fi
    perl -e 'select undef, undef, undef, 0.25' 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
}

# --- 6. Sessions ---
# The licence caps concurrent sessions, so a scenario signs out in its own `finally`.
# KEEP_SESSION=1 / MDL_SESSION_REUSE=1: stay signed in, reused for the same TEST_USER. FRESH_SESSION=1: never reuse.
# Both flags are 1 or 0: they are written into the scenario's JavaScript as numbers.
if [ "${KEEP_SESSION:-0}" = "1" ] || [ "${MDL_SESSION_REUSE:-0}" = "1" ]; then
  _MDL_RELEASE=0   # stay signed in after the scenario
  _MDL_REUSE=1     # and pick that session up in the next one
else
  _MDL_RELEASE=1
  _MDL_REUSE=0
fi
if [ "${FRESH_SESSION:-0}" = "1" ]; then _MDL_REUSE=0; fi
# EXIT handler: stop the watchdog, report a timeout set -e hid, remove temp files, sign out after a timeout.
_release_session() {
  local status=$?
  kill "$_MDL_WATCHDOG" 2>/dev/null || true
  if [ "$_MDL_TIMED_OUT" = "0" ] && [ -f "$_MDL_TIMEOUT_FLAG" ]; then
    _mdl_timeout_message
    _MDL_TIMED_OUT=1
    status=124
  fi
  rm -f "$_MDL_TIMEOUT_FLAG"
  # The scenario file holds the password.
  [ -n "${_MDL_SCENARIO_FILE:-}" ] && rm -f "$_MDL_SCENARIO_FILE"
  # Only a timed-out scenario skipped its sign-out; bounded because that browser hung.
  if [ "$_MDL_TIMED_OUT" = "1" ] && [ "$_MDL_RELEASE" = "1" ] && [ -n "$TEST_PASSWORD" ]; then
    _mdl_bounded 5 playwright-cli run-code \
      "async () => { try { await page.evaluate(() => { if (window.mx && mx.logout) mx.logout(); }); } catch (e) {} return true; }" || true
  fi
  return $status
}
trap _release_session EXIT

# release_session -- sign out within 10s, never fails; gate.sh calls it after a reuse run.
release_session() {
  _mdl_bounded 10 playwright-cli run-code \
    "async () => { try { await page.evaluate(() => { if (window.mx && mx.logout) mx.logout(); }); await page.waitForSelector('#usernameInput, input[name=username]', {timeout: 5000}); } catch (e) {} return true; }" || true
}

# Print a session refusal logged in the last 2 minutes; return 1 if none.
_licence_refusal() {
  [ -f "$RUNTIME_LOG" ] || return 1
  tail -400 "$RUNTIME_LOG" 2>/dev/null | grep "Maximum number of sessions exceeded" | tail -1 \
    | "$PY" -c "
import datetime, re, sys
line = sys.stdin.read().strip()
if not line:
    sys.exit(1)
stamp = re.match(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', line)
if not stamp:
    sys.exit(1)
when = datetime.datetime.strptime(stamp.group(1), '%Y-%m-%d %H:%M:%S')
if (datetime.datetime.now() - when).total_seconds() > 120:
    sys.exit(1)
print('the runtime refused a session: Maximum number of sessions exceeded (developer/trial licence caps concurrent sessions). Close leftover test browsers and developer tabs, or restart the runtime')
"
}

# --- 7. scenario ---
# scenario '<js body>' -- run the body in one playwright-cli process; print its return as JSON, fail() on error.
# Steps: write the JavaScript to a file, run it, fail on an error, print the result.
scenario() {
  local body="$1"
  local code_file output
  code_file="$(mdl_tmpfile mdl-scenario)"
  # Written to a file: bodies contain double quotes.
  _mdl_scenario_js "$body" > "$code_file"

  # So the EXIT trap can delete it (it holds the password) after a timeout.
  _MDL_SCENARIO_FILE="$code_file"
  output="$(playwright-cli run-code "$(cat "$code_file")" 2>&1)"
  rm -f "$code_file"; _MDL_SCENARIO_FILE=""

  # Called directly, not in $(...): fail() must end the script, not a subshell.
  _mdl_fail_on_scenario_error "$output"
  _mdl_scenario_result "$output"
}

# _mdl_scenario_js <body> -- the whole async function: settings, helpers, then the body in try/catch.
_mdl_scenario_js() {
  local body="$1"
  printf 'async () => {\n'
  _mdl_js_settings
  _mdl_js_helpers
  # verify shows only the last stderr line, so the catch adds url and user to the error.
  printf '  try {\n'
  printf '%s\n' "$body"
  _mdl_js_catch_and_sign_out
  printf '}\n'
}

# The JS constants: BASE, USER, PASSWORD, ACTION_TIMEOUT, RELEASE, REUSE.
_mdl_js_settings() {
  # JSON-encoded: these values are data, and an apostrophe must not end the JS string.
  printf '  const MDL_CFG = JSON.parse(%s);\n' "$(mdl_json_string \
    "$(mdl_json_object BASE "$BASE_URL" USER "$TEST_USER" PASSWORD "$TEST_PASSWORD")")"
  printf '  const BASE = MDL_CFG.BASE;\n'
  printf '  const USER = MDL_CFG.USER;\n'
  printf '  const PASSWORD = MDL_CFG.PASSWORD;\n'
  printf '  const ACTION_TIMEOUT = %s;\n' "$(mdl_json_number "${ACTION_TIMEOUT_MS:-8000}" 8000)"
  printf '  const RELEASE = %s;\n' "$_MDL_RELEASE"
  printf '  const REUSE = %s;\n' "$_MDL_REUSE"
}

# The JS helpers a body calls: open_app, menu, fill, ... (listed at the top of this file).
_mdl_js_helpers() {
  cat <<'PRELUDE'
  // Playwright waits 30s by default for a missing element. During development the
  // failing case is the normal case, so fail in 8s instead -- red runs are what
  // cost time, not green ones. Override per call where a step is genuinely slow.
  page.setDefaultTimeout(ACTION_TIMEOUT);

  const LOGIN_FIELD = '#usernameInput, input[name=username]';
  // '/' redirects to login.html, and the redirect finishes after goto returns --
  // so wait for whichever of the two arrives rather than deciding immediately,
  // or the form is never seen and .mx-page never comes.
  const sign_in_if_asked = async () => {
    await page.waitForSelector(LOGIN_FIELD + ', .mx-page', {timeout: 20000});
    if (!(await page.locator(LOGIN_FIELD).count())) return;
    if (!PASSWORD) throw new Error('app shows a login page but TEST_PASSWORD is empty');
    // Login-page selectors only. `.alert` and `.mx-validation-message` also occur on
    // ordinary pages, and a race that matched those would report a refused sign-in
    // for an app that had loaded perfectly well.
    const LOGIN_ERROR = '#loginMessage, .login-message, .alert-danger, .mx-login .alert';
    let landed = 'gone';
    // Two attempts. A sign-in sent the instant the login page appears after a
    // sign-out is refused now and then with a bare "Sign in failed" (seen once in
    // ~10 suite runs, always right after switching users), and the same form
    // submitted again a moment later is accepted. Wrong credentials fail both
    // times and are reported as before.
    for (let attempt = 1; attempt <= 2; attempt++) {
      await page.fill(LOGIN_FIELD, USER);
      await page.fill('#passwordInput, input[name=password]', PASSWORD);
      await page.click('#loginButton, button[type=submit], form button');
      // Race the app against the login page's own error: a refused sign-in is on
      // screen in about a second, and waiting out the 20s timeout for .mx-page turns
      // "wrong password" into an unexplained hang.
      landed = await Promise.race([
        page.waitForSelector('.mx-page', {timeout: 20000}).then(() => 'page').catch(() => 'gone'),
        page.waitForSelector(LOGIN_ERROR, {timeout: 20000}).then(() => 'error').catch(() => 'gone'),
      ]);
      if (!(landed === 'error' && /login/.test(page.url()) && attempt === 1)) break;
      await page.waitForTimeout(700);
    }
    // Still on the login page is part of the claim: an error element that appears as
    // the app renders must not be read as a refusal.
    if (landed === 'error' && /login/.test(page.url())) {
      const said = await page.locator(LOGIN_ERROR).first().innerText()
        .then(t => t.replace(/\s+/g, ' ').trim()).catch(() => '');
      throw new Error('sign-in as ' + USER + ' was refused: ' + (said || 'the login page reported an error')
        + ' (credentials come from tests/credentials.env)');
    }
    await page.waitForSelector('.mx-page', {timeout: 20000});
  };
  // Ending a session, not just forgetting it. Clearing cookies leaves the old
  // session alive on the server, and the runtime's session limit then refuses the
  // next sign-in with "Maximum number of sessions exceeded" -- which reaches the
  // browser as a plain "Sign in failed".
  const current_user = async () => page.evaluate(() => {
    try { const a = mx.session.sessionData.user.attributes.Name; return (a && a.value) || ''; }
    catch (e) { return ''; }
  }).catch(() => '');
  const sign_out = async () => {
    if (await page.locator('.mx-page').count()) {
      await page.evaluate(() => { if (window.mx && window.mx.logout) window.mx.logout(); });
    }
    await page.waitForSelector(LOGIN_FIELD, {timeout: 20000});
  };
  // Always start from a fresh sign-in. The runtime's licence caps concurrent
  // sessions, and a session left behind by an earlier run counts against it --
  // the next sign-in then fails with a bare "Sign in failed" on the login page.
  // A mid-scenario page.goto wipes client state, hides carry-over between steps, and
  // above Security Level: Off it is a silent sign-out -- the suite then continues as
  // though navigation worked. Navigate with menu()/row_action(); to deliberately start
  // over, call reopen_app().
  let __journey_started = false;
  // The page object lives in the playwright-cli daemon and outlives one scenario, so a
  // guard installed last time is still on it. Restore the real goto first, or each
  // scenario wraps the previous scenario's already-tripped guard.
  if (page.__mdl_raw_goto) page.goto = page.__mdl_raw_goto;
  const __goto = page.goto.bind(page);
  page.__mdl_raw_goto = page.goto;
  page.goto = async (url, options) => {
    if (__journey_started) {
      throw new Error('page.goto(' + url + ') after the app was opened is a mid-journey reload:'
        + ' it wipes client state and, with security on, signs the session out. Navigate with'
        + ' menu() or row_action(), or call reopen_app() to deliberately start a fresh journey.');
    }
    return __goto(url, options);
  };
  const reopen_app = async () => { __journey_started = false; await open_app(); };

  const open_app = async () => {
    await page.goto(BASE + '/');
    await page.waitForSelector(LOGIN_FIELD + ', .mx-page', {timeout: 20000});
    // Signing out only makes sense where there is something to sign in to. With
    // Security Level: Off there is no login page, so mx.logout() would leave the
    // scenario waiting 20s for a form that never appears -- and the failure then
    // reads as a broken feature. Say so instead, before spending the 20s.
    if (PASSWORD && await page.locator('.mx-page').count()) {
      const who = await current_user();
      if (/^Anonymous/.test(who)) {
        throw new Error('the app is signed in as ' + who + ' and shows no login page, so TEST_USER='
          + USER + ' cannot be applied: this app runs with Security Level: Off. Unset TEST_USER and'
          + ' TEST_PASSWORD (and remove tests/credentials.env) for this app, or turn security on');
      }
      // A session the previous script left signed in as this same user is this
      // script's session too (MDL_SESSION_REUSE / KEEP_SESSION). Anyone else's is
      // ended first: the tests for another role must not run as this one.
      if (!(REUSE && who === USER)) await sign_out();
    }
    await sign_in_if_asked();
    await page.waitForSelector('.mx-page', {timeout: 20000});
    __journey_started = true;
  };
  // await_message(/reminder sent/i) -- wait for the text the app shows in reply to
  // an action, wherever it puts it: a dialog, an alert bar, or a rendered message
  // on the page. Returns the visible text so the test can assert on it. This
  // replaces `waitForTimeout(1500)` followed by page_text(): it returns as soon as
  // the message is there (~200ms) instead of after a fixed pause, and it fails
  // saying what WAS on screen when the message never came, rather than handing the
  // test an unrelated page to assert against.
  // The pattern must match the MESSAGE and nothing the page showed before the
  // action: a button captioned "Unpaid" satisfies /unpaid/ instantly, and the
  // test then reads a page on which the message has not appeared yet. Include a
  // word or a number that only the message carries: /has \d+ unpaid invoice/i.
  const await_message = async (pattern, timeout) => {
    const deadline = Date.now() + (timeout || ACTION_TIMEOUT);
    let text = '';
    for (;;) {
      text = await page.locator('body').innerText().catch(() => '');
      if (pattern.test(text)) return text.replace(/\s+/g, ' ').trim();
      if (Date.now() > deadline) {
        throw new Error('no message matching ' + pattern + ' appeared within '
          + (timeout || ACTION_TIMEOUT) + 'ms; the page says: '
          + text.replace(/\s+/g, ' ').trim().slice(0, 300));
      }
      await page.waitForTimeout(100);
    }
  };
  // Mendix commits an input on blur, so a fill followed straight away by a click
  // on Save can be saved before the last value is committed. Tab out to blur.
  const fill = async (widget, value) => {
    const input = page.locator('.mx-name-' + widget + ' input, .mx-name-' + widget + ' textarea').first();
    await input.fill(String(value));
    await input.press('Tab');
  };
  const pick_combo = async (widget, option) => {
    await page.click('.mx-name-' + widget + ' .widget-combobox-input-container');
    const item = page.locator('.widget-combobox-item', {hasText: option}).first();
    await item.waitFor({timeout: 10000});
    await item.click();
  };
  const row_action = async (grid, row_text, widget) => {
    const row = page.locator('.mx-name-' + grid + ' [role=row]', {hasText: row_text}).first();
    await row.waitFor({timeout: 15000});
    await row.locator('.mx-name-' + widget).click();
  };
  // Prove the page arrived before anything asserts against it. Without this, a nav
  // click that silently did nothing leaves the next assertions measuring the PREVIOUS
  // page, and the failures that follow describe a defect that does not exist.
  const landed = async (widget, what) => {
    const ok = await page.locator('.mx-name-' + widget).first()
      .waitFor({timeout: 10000}).then(() => true).catch(() => false);
    if (!ok) {
      throw new Error('did NOT land after ' + what + ': .mx-name-' + widget
        + ' never appeared (on ' + page.url() + '). Everything after this would have been'
        + ' asserted against the previous page.');
    }
  };
  // menu('Invoices', 'invoiceGrid') -- the second argument is the widget that proves
  // arrival, and is the right way to click a menu item. With one argument the guard
  // falls back to "something must have happened": a menu item that is a microflow
  // action opens a dialog rather than a page, and both count.
  const menu = async (label, ready) => {
    const candidates = page.locator('.mx-navigationtree a, nav a, a').filter({hasText: label});
    await candidates.first().waitFor({timeout: 10000});
    // An Atlas layout renders its menu twice -- the top bar and the off-canvas
    // sidebar. Both report themselves visible, but the collapsed one sits under a
    // .mx-placeholder overlay, so clicking it times out as "element is not stable"
    // and the failure reads as a missing menu item. Click the copy a real pointer
    // would reach. (Found by a session that lost several minutes to it.)
    let link = candidates.first();
    const total = await candidates.count();
    for (let i = 0; i < total; i++) {
      const reachable = await candidates.nth(i).evaluate(el => {
        const r = el.getBoundingClientRect();
        if (!r.width || !r.height) return false;
        const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
        return !!hit && (hit === el || el.contains(hit) || hit.contains(el));
      }).catch(() => false);
      if (reachable) { link = candidates.nth(i); break; }
    }
    const before = (await page.locator('.mx-page').first().innerText().catch(() => '')).slice(0, 300);
    const url_before = page.url();
    await link.click();
    if (ready) { await landed(ready, "menu '" + label + "'"); return; }
    const deadline = Date.now() + 3000;
    for (;;) {
      const after = (await page.locator('.mx-page').first().innerText().catch(() => '')).slice(0, 300);
      const dialog = await page.locator('.modal-footer button, .mx-dialog').count();
      if (after !== before || dialog > 0 || page.url() !== url_before) return;
      if (Date.now() > deadline) {
        throw new Error("clicked menu '" + label + "' but nothing happened within 3s: no page"
          + ' change, no dialog (on ' + page.url() + '). If this item leads to a page you are'
          + " already on, pass the widget that proves it: menu('" + label + "', 'someGrid').");
      }
      await page.waitForTimeout(150);
    }
  };
  const dismiss_dialog = async () => {
    const ok = page.locator('.modal-footer button, .mx-dialog button').filter({hasText: 'OK'});
    if (await ok.count()) await ok.first().click();
  };
  const page_text = async () => (await page.locator('body').innerText());
PRELUDE
}

# The end of the try: the catch adds url, user and login message; the finally signs out.
_mdl_js_catch_and_sign_out() {
  cat <<'CATCH'
  } catch (e) {
    const url = page.url();  // synchronous in Playwright; do not await or .catch it
    // mx is absent on login.html, so asking for the user there throws. Neither
    // getUserName() nor getUserAttribute() exists on mx.session in 11.12 -- the
    // name sits in sessionData, as {value: 'demo_administrator'}. Measured.
    const who = await current_user();
    const why = String((e && e.message) || e).split('\n').map(l => l.trim()).filter(Boolean).slice(0, 3).join(' | ');
    // A refused sign-in leaves a message on the login page; without it the failure
    // reads as a plain selector timeout and says nothing about the cause.
    let note = '';
    if (/login/.test(url)) {
      note = await page.locator('.login-message, .alert, #loginMessage, .mx-validation-message').first()
        .innerText({timeout: 500}).then(t => t.replace(/\s+/g, ' ').trim()).catch(() => '');
    }
    throw new Error(why + ' [on ' + url + (who ? ', signed in as ' + who : '') + (note ? ', page says: ' + note : '') + ']');
  } finally {
    // Release the session here, in-process, on success and on failure alike. Only
    // where there was a sign-in: with Security Level: Off there is no session to
    // end and no login page to wait for. The short wait lets the logout request
    // reach the runtime before the process ends -- a navigation right after
    // mx.logout() would cancel it and leave the session counted.
    if (RELEASE && PASSWORD) {
      try {
        await page.evaluate(() => { if (window.mx && window.mx.logout) window.mx.logout(); });
        await page.waitForSelector(LOGIN_FIELD, {timeout: 5000});
      } catch (e) {}
    }
    // The goto guard is this scenario's, not the page's: left in place it refused
    // the next hand-run `playwright-cli run-code` probe as a "mid-journey reload".
    page.goto = page.__mdl_raw_goto;
  }
CATCH
}

# _mdl_fail_on_scenario_error <output> -- fail() when playwright-cli reported an error or no result.
# playwright-cli prints its answer in sections headed "### Result" or "### Error".
_mdl_fail_on_scenario_error() {
  local output="$1"
  if printf '%s' "$output" | grep -q '^### Error'; then
    # Full block to stderr; a one-line summary in fail(), the only line verify reprints.
    printf '%s\n' "$output" | sed -n '/^### Error/,/^###/p' | head -8 >&2
    local why
    why="$(_mdl_error_summary "$output")"
    local refusal
    refusal="$(_licence_refusal || true)"
    fail "browser scenario failed: ${why:-no error text}${refusal:+ -- $refusal}"
  fi
  # Neither marker: the code never ran (e.g. browser not open).
  if ! printf '%s' "$output" | grep -q '^### Result'; then
    fail "browser scenario produced no result: $(printf '%s' "$output" | tr '\n' ' ' | tr -s ' ' | cut -c1-200) (running a test outside the runner needs: playwright-cli open)"
  fi
}

# _mdl_error_summary <output> -- the "### Error" text on one line, colours removed, at most 400 chars.
_mdl_error_summary() {
  printf '%s\n' "$1" \
    | sed -n '/^### Error/,/^### [A-Z]/p' | sed '1d;/^### /d' \
    | sed $'s/\033\[[0-9;]*m//g' | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ $//' | cut -c1-400
}

# _mdl_scenario_result <output> -- print the "### Result" section without blank lines.
_mdl_scenario_result() {
  printf '%s' "$1" | awk '/^### Result/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d'
}

# --- 8. Reading the result ---
# field <json> <key> -- booleans and null as JSON spells them; plain strings unquoted.
field() {
  local json="$1" key="$2"
  printf '%s' "$json" | "$PY" -c "
import json, sys
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print('')
    sys.exit()
if isinstance(data, str):
    data = json.loads(data)
value = data.get(sys.argv[1], '')
print(value if isinstance(value, str) else json.dumps(value))
" "$key"
}

# fields <json> <key...> -- one line per key, as field(), in one Python start:
#   { read -r opened; read -r count; } <<< "$(fields "$result" opened count)"
fields() {
  local json="$1"; shift
  printf '%s' "$json" | "$PY" -c "
import json, sys
raw = sys.stdin.read().strip()
keys = sys.argv[1:]
try:
    data = json.loads(raw)
    if isinstance(data, str):
        data = json.loads(data)
except json.JSONDecodeError:
    data = {}
for key in keys:
    value = data.get(key, '')
    print(value if isinstance(value, str) else json.dumps(value))
" "$@"
}

# --- 9. Data assertions (~0.03s each) ---
# oql "<query>" -- rows as JSON, or fail with mxcli's own error. Qualify entities: $MODULE.Invoice.
oql() {
  local query="$1" output
  # `if !` keeps the output and stops set -e exiting before the error is reported.
  if ! output="$("$MXCLI" oql -p "$APP_DIR/$MPR" --host "${ADMIN_HOST:-localhost}" \
                 --port "${ADMIN_PORT:-8090}" --json "$query" 2>&1)"; then
    fail "OQL failed: $(printf '%s' "$output" | grep -v '^$' | head -2 | tr '\n' ' ')"
  fi
  # mxcli appends a "(n rows)" line, so decode only the first JSON value.
  local json
  json="$(printf '%s' "$output" | "$PY" -c "
import json, sys
text = sys.stdin.read()
start = text.find('[')
if start < 0:
    sys.exit(1)
try:
    value, _ = json.JSONDecoder().raw_decode(text[start:])
except ValueError:
    sys.exit(1)
print(json.dumps(value))
")" || fail "OQL returned nothing to parse: $(printf '%s' "$output" | grep -v '^$' | head -2 | tr '\n' ' ')"
  printf '%s' "$json"
}

# oql_count <Entity> ["<where>"] -- WHERE is OQL: reach associations with JOIN, not paths.
oql_count() {
  local entity="$1" where="${2:-}"
  [ -n "${MODULE:-}" ] || fail "oql_count needs a module: set MODULE=<YourModule> or run through tests/gate.sh"
  local query="SELECT COUNT(*) AS Total FROM $MODULE.$entity"
  # Not `[ -n "$where" ] && ...`: with set -e, the false test ends the function.
  if [ -n "$where" ]; then
    query="$query WHERE $where"
  fi
  # Captured, not piped: a failing oql must stop here, not feed python empty input.
  local json
  json="$(oql "$query")" || exit 1
  printf '%s' "$json" | "$PY" -c "
import json, sys
rows = json.load(sys.stdin)
print(rows[0].get('Total', 0) if rows else 0)
"
}

# await_row <Entity> "<where>" [seconds] -- 0 once a row matches, 1 after <seconds> (default 8)
# or when the query itself fails.
await_row() {
  local entity="$1" where="$2" limit="${3:-8}" waited=0 count
  while :; do
    count="$(oql_count "$entity" "$where")" || return 1
    [ "$count" = "0" ] || return 0
    waited=$((waited + 1))
    [ "$waited" -ge "$((limit * 4))" ] && return 1
    perl -e 'select undef, undef, undef, 0.25'
  done
  return 0
}

# oql_value <Entity> <Attr> "<where>" -- 'no-such-row' if none; 'empty' for null or "";
# booleans print true/false, numbers as they are (0 stays 0).
oql_value() {
  local entity="$1" attribute="$2" where="$3"
  local json
  [ -n "${MODULE:-}" ] || fail "oql_value needs a module: set MODULE=<YourModule> or run through tests/gate.sh"
  json="$(oql "SELECT $attribute FROM $MODULE.$entity WHERE $where")" || exit 1
  printf '%s' "$json" | "$PY" -c "
import json, sys
rows = json.load(sys.stdin)
if not rows:
    print('no-such-row')
else:
    value = rows[0].get(sys.argv[1])
    if value is None or value == '':
        print('empty')
    elif isinstance(value, bool):
        print('true' if value else 'false')
    else:
        print(value)
" "$attribute"
}
