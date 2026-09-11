#!/usr/bin/env bash
# Shared helpers for the verify-*.test.sh scripts.
#
# The design rule here is about speed, and it is the only thing that matters for
# how these tests are written:
#
#   ONE browser scenario per test, not one call per click.
#
# `playwright-cli eval` costs about 0.66s per invocation -- process launch and
# connect, before any browser work happens. A test written as twenty helper calls
# therefore pays ~13s of pure process spawning; measured, `verify-escalate` spent
# roughly half its 35.6s that way. `scenario` runs the whole flow in a single
# `playwright-cli run-code` process instead, so a test costs one spawn plus the
# browser work it actually needs.
#
# Data assertions stay in the shell, where they are cheap: `mxcli oql` costs
# ~0.03s, so asserting against the database is effectively free.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8081}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MPR="${MPR:-$(cd "$APP_DIR" && ls -1 *.mpr | head -1)}"
# mxcli.exe vs mxcli, python vs python3, GNU vs BSD mktemp -- see tests/portable.sh.
# MXCLI from the environment still wins; portable.sh only fills a blank.
PORTABLE_APP_DIR="$APP_DIR"
. "$(dirname "${BASH_SOURCE[0]}")/portable.sh"

# Credentials, used only when the app has security on and shows a login page.
#
# The password cannot be discovered from the model -- it is not in the .mpr, and
# `SHOW DEMO USERS` reports names and roles only (checked). So rather than have every
# session patch this file by hand (two sessions did, with two different passwords),
# it is read from the project, in this order:
#
#   1. TEST_PASSWORD / TEST_USER in the environment            (one run)
#   2. tests/credentials.env                                   (the project's answer)
#        TEST_USER=demo_collector
#        TEST_PASSWORD=SomePass12345
#        TEST_PASSWORD_demo_customer=OtherPass12345   # per-user, optional
#   3. nothing -- correct for an app with Security Level: Off
#
# TEST_USER belongs there too, not as a default here: the canonical tests drive the
# staff screens, and which role may open those is a decision each app makes. An app
# that switches security on with the wrong user gets five red tests whose real cause
# is "this user cannot see the button".
CREDENTIALS="${CREDENTIALS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/credentials.env}"
if [ -z "${TEST_USER:-}" ] && [ -f "$CREDENTIALS" ]; then
  _user_line="$(grep -E '^TEST_USER=' "$CREDENTIALS" 2>/dev/null | tail -1 || true)"
  TEST_USER="${_user_line#*=}"
fi
TEST_USER="${TEST_USER:-demo_administrator}"
if [ -z "${TEST_PASSWORD:-}" ] && [ -f "$CREDENTIALS" ]; then
  # Read as data, not sourced: a credentials file must not be able to run commands.
  # `|| true` matters: no match makes grep exit 1, and under `set -e` with pipefail
  # the failed pipeline would end the script during `source`, silently.
  _per_user="$(grep -E "^TEST_PASSWORD_${TEST_USER}=" "$CREDENTIALS" 2>/dev/null | tail -1 || true)"
  _shared="$(grep -E '^TEST_PASSWORD=' "$CREDENTIALS" 2>/dev/null | tail -1 || true)"
  TEST_PASSWORD="${_per_user#*=}"
  [ -n "$TEST_PASSWORD" ] || TEST_PASSWORD="${_shared#*=}"
  TEST_PASSWORD="${TEST_PASSWORD%\"}"; TEST_PASSWORD="${TEST_PASSWORD#\"}"
fi
TEST_PASSWORD="${TEST_PASSWORD:-}"

# The runtime log is where a licence refusal is explained; the browser only shows a
# failed sign-in. Read from it rather than guessing at the cause.
RUNTIME_LOG="${RUNTIME_LOG:-$APP_DIR/.mxcli/runtime.log}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A developer/trial licence caps concurrent sessions -- measured on this runtime, the
# 7th live session was refused, and the app logged 60 refusals of "Maximum number of
# sessions exceeded! (You are currently using a trial license)" in one evening. Every
# session a test leaves behind counts towards that cap until it times out, so release
# it: open_app signs the previous session out, and this signs out at the end of the
# script, so a warm --keep-open browser does not hold one between runs either.
#
# Set KEEP_SESSION=1 to leave the session signed in (debugging a page by hand).
SCENARIO_RAN=0
_release_session() {
  local status=$?
  if [ "$SCENARIO_RAN" = "1" ] && [ "${KEEP_SESSION:-0}" != "1" ]; then
    playwright-cli run-code "async () => { try { await page.evaluate(() => { if (window.mx && mx.logout) mx.logout(); }); } catch (e) {} return true; }" >/dev/null 2>&1
  fi
  return $status
}
trap _release_session EXIT

# Did the runtime just refuse a session? Only a refusal in the last two minutes is
# about this run.
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

# --- the one browser call ----------------------------------------------------
#
# Runs a JavaScript body in Node with Playwright's `page` in scope, and prints
# whatever it returns as JSON. The body may use `await` freely.
#
#   result="$(scenario '
#     await open_app();
#     await page.click(".mx-name-btnNewInvoice");
#     return {open: await page.locator(".mx-name-txtNumber").count()};
#   ')"
#
# Helpers available inside the body: open_app, fill, pick_combo, row_action,
# page_text, dismiss_dialog, menu. They are plain Playwright underneath -- the
# point is that they run in-process, so they cost milliseconds rather than a
# process launch each.
scenario() {
  local body="$1"
  local code_file output
  code_file="$(mdl_tmpfile mdl-scenario)"
  # The body is written to a file rather than interpolated into a command string:
  # scenarios contain double quotes, which would terminate the outer shell string.
  {
    printf 'async () => {\n'
    printf "  const BASE = '%s';\n" "$BASE_URL"
    printf "  const USER = '%s';\n" "$TEST_USER"
    printf "  const PASSWORD = '%s';\n" "$TEST_PASSWORD"
    printf '  const ACTION_TIMEOUT = %s;\n' "${ACTION_TIMEOUT_MS:-8000}"
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
    await page.fill(LOGIN_FIELD, USER);
    await page.fill('#passwordInput, input[name=password]', PASSWORD);
    await page.click('#loginButton, button[type=submit], form button');
    // Race the app against the login page's own error: a refused sign-in is on
    // screen in about a second, and waiting out the 20s timeout for .mx-page turns
    // "wrong password" into an unexplained hang.
    // Login-page selectors only. `.alert` and `.mx-validation-message` also occur on
    // ordinary pages, and a race that matched those would report a refused sign-in
    // for an app that had loaded perfectly well.
    const LOGIN_ERROR = '#loginMessage, .login-message, .alert-danger, .mx-login .alert';
    const landed = await Promise.race([
      page.waitForSelector('.mx-page', {timeout: 20000}).then(() => 'page').catch(() => 'gone'),
      page.waitForSelector(LOGIN_ERROR, {timeout: 20000}).then(() => 'error').catch(() => 'gone'),
    ]);
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
      await sign_out();
    }
    await sign_in_if_asked();
    await page.waitForSelector('.mx-page', {timeout: 20000});
    __journey_started = true;
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
    const link = page.locator('.mx-navigationtree a, nav a, a').filter({hasText: label}).first();
    await link.waitFor({timeout: 10000});
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
    # The body runs inside a try, so a throw can be re-raised carrying the page it
    # happened on and who was signed in. `mxcli playwright verify` shows only the
    # last stderr line of a script, so everything needed to diagnose has to be in
    # that one line -- otherwise the next step is re-running the script by hand.
    printf '  try {\n'
    printf '%s\n' "$body"
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
  }
CATCH
    printf '}\n'
  } > "$code_file"

  SCENARIO_RAN=1
  output="$(playwright-cli run-code "$(cat "$code_file")" 2>&1)"
  rm -f "$code_file"

  if printf '%s' "$output" | grep -q '^### Error'; then
    # The full block goes to stderr for a human reading the script's own output,
    # and the same text is collapsed into the fail() line, because that line is
    # all `mxcli playwright verify` reprints. "browser scenario threw" on its own
    # cost this project several debugging rounds per failure.
    printf '%s\n' "$output" | sed -n '/^### Error/,/^###/p' | head -8 >&2
    local why
    why="$(printf '%s\n' "$output" \
      | sed -n '/^### Error/,/^### [A-Z]/p' | sed '1d;/^### /d' \
      | sed $'s/\033\[[0-9;]*m//g' | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ $//' | cut -c1-400)"
    local refusal
    refusal="$(_licence_refusal || true)"
    fail "browser scenario failed: ${why:-no error text}${refusal:+ -- $refusal}"
  fi
  # No result and no error means playwright-cli never ran the code -- most often
  # "The browser 'default' is not open", which it reports without the ### Error
  # marker. Left unchecked, `scenario` returns an empty string, every `field` reads
  # empty, and the test fails on an assertion that had nothing to assert against.
  if ! printf '%s' "$output" | grep -q '^### Result'; then
    fail "browser scenario produced no result: $(printf '%s' "$output" | tr '\n' ' ' | tr -s ' ' | cut -c1-200) (running a test outside the runner needs: playwright-cli open)"
  fi
  printf '%s' "$output" | awk '/^### Result/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d'
}

# Read one field out of a scenario's JSON result.
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
value = data.get('$key', '')
print(json.dumps(value) if isinstance(value, (dict, list)) else value)
"
}

# --- data assertions, ~0.03s each --------------------------------------------
#
# A failing query prints its error on stderr and nothing on stdout, so parsing the
# output blind turns "your OQL is wrong" or "the app is not running" into a Python
# traceback. Surface mxcli's own message instead.
oql() {
  local query="$1" output
  if ! output="$("$MXCLI" oql -p "$APP_DIR/$MPR" --json "$query" 2>&1)"; then
    fail "OQL failed: $(printf '%s' "$output" | grep -v '^$' | head -2 | tr '\n' ' ')"
  fi
  # mxcli prints the JSON and then a human line -- "(1 rows)", or "[]" and "(0 rows)"
  # for an empty result -- so decode the first JSON value rather than matching lines.
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

# oql_count Invoice "InvoiceNumber = 'INV-1001'"  ->  a number
#
# The WHERE is OQL, not XPath: an association is reached with a JOIN, not with a
# path. To count a customer's invoices, join and constrain on the joined alias:
#
#   oql "SELECT COUNT(*) AS Total FROM InvoiceDesk.Invoice AS i
#        JOIN i/InvoiceDesk.Invoice_Customer/InvoiceDesk.Customer AS c
#        WHERE c/Name = 'Northwind Traders'"
oql_count() {
  local entity="$1" where="${2:-}"
  local query="SELECT COUNT(*) AS Total FROM InvoiceDesk.$entity"
  # Not `[ -n "$where" ] && ...`: with set -e, the false test ends the function.
  if [ -n "$where" ]; then
    query="$query WHERE $where"
  fi
  # Capture rather than pipe: `oql` fails inside a subshell, and a pipeline would
  # carry on and hand empty input to python, turning a clear error into a traceback.
  local json
  json="$(oql "$query")" || exit 1
  printf '%s' "$json" | "$PY" -c "
import json, sys
rows = json.load(sys.stdin)
print(rows[0].get('Total', 0) if rows else 0)
"
}

# Wait for a row to appear, polling the database. An OQL call is ~0.03s, so this
# is far cheaper than waiting in the browser, and it asserts on what was stored
# rather than on what was rendered.
# await_row Invoice "InvoiceNumber = 'TEST-1'" [seconds]
await_row() {
  local entity="$1" where="$2" limit="${3:-8}" waited=0
  while [ "$(oql_count "$entity" "$where")" = "0" ]; do
    waited=$((waited + 1))
    [ "$waited" -ge "$((limit * 4))" ] && return 1
    perl -e 'select undef, undef, undef, 0.25'
  done
  return 0
}

# oql_value Invoice Status "InvoiceNumber = 'INV-1001'"  ->  the value, or 'empty'
oql_value() {
  local entity="$1" attribute="$2" where="$3"
  local json
  json="$(oql "SELECT $attribute FROM InvoiceDesk.$entity WHERE $where")" || exit 1
  printf '%s' "$json" | "$PY" -c "
import json, sys
rows = json.load(sys.stdin)
print((rows[0].get('$attribute') or 'empty') if rows else 'no-such-row')
"
}
