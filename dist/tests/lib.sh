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

# --- the script's own time limit ---------------------------------------------
#
# `mxcli playwright verify` kills a script at --timeout, but a script run by hand
# (`bash tests/verify-x.test.sh`) had no limit at all: one session's hand-run test
# hung for 801s on a browser call that never returned, and another for 1141s. And
# the runner's kill is a bare SIGKILL of bash -- the stuck `playwright-cli run-code`
# child survives it, keeps the shared browser busy, and the NEXT script hangs the
# same way.
#
# So every script carries its own limit. SCRIPT_TIMEOUT -- the gate's knob, "90s"
# or "90" -- sets it, and it fires 5s before the runner would, so it is this trap,
# which kills the child and names the cause, that reports -- not the runner's bare
# "timeout after 1m30s".
_MDL_LIMIT="${SCRIPT_TIMEOUT:-90}"; _MDL_LIMIT="${_MDL_LIMIT%s}"
case "$_MDL_LIMIT" in ''|*[!0-9]*) _MDL_LIMIT=90 ;; esac
if [ "$_MDL_LIMIT" -gt 15 ]; then _MDL_LIMIT=$((_MDL_LIMIT - 5)); fi

# Every process under <pid>, deepest first, except the caller. pgrep where it
# exists; Git Bash has only `ps -ef` (PID, PPID as the first two columns).
_mdl_descendants() {
  local child
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

# The timeout is delivered in two steps because of how bash handles signals: a
# trapped signal that arrives while a foreground command runs -- and a test body
# is one long `result="$(scenario ...)"` -- is held until that command ends. So
# the sleeper first leaves a marker, then ends every process under this script
# (the stuck playwright-cli among them), which lets the deferred TERM trap run.
_MDL_TIMEOUT_FLAG="$(mdl_tmpfile mdl-watchdog)"; rm -f "$_MDL_TIMEOUT_FLAG"
_MDL_TIMED_OUT=0
_mdl_timed_out() {
  _MDL_TIMED_OUT=1
  echo "FAIL: test exceeded ${_MDL_LIMIT}s (SCRIPT_TIMEOUT): a browser call or a polling loop never returned." \
       "If the next test hangs too, the browser is stuck: playwright-cli close && playwright-cli open" >&2
  _mdl_kill_tree $$
  exit 124
}
trap _mdl_timed_out TERM
# The sleeper dies with its subshell, so a finished script leaves no `sleep`
# behind for the rest of the limit.
( trap 'kill $! 2>/dev/null; exit 0' TERM
  sleep "$_MDL_LIMIT" & wait $!
  : > "$_MDL_TIMEOUT_FLAG"
  kill -TERM $$ 2>/dev/null
  _mdl_kill_tree $$ ) 2>/dev/null &
_MDL_WATCHDOG=$!

# _mdl_bounded <seconds> <command...> -- run it, but give up after <seconds>. For the
# clean-up that runs after a timeout: the browser that just hung is the one being
# asked to log out, so the request must not be allowed to hang as well.
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

# --- sessions -----------------------------------------------------------------
#
# A developer/trial licence caps concurrent sessions -- measured on this runtime, the
# 7th live session was refused, and the app logged 60 refusals of "Maximum number of
# sessions exceeded! (You are currently using a trial license)" in one evening. Every
# session a test leaves behind counts towards that cap until it times out, so a
# scenario signs out in its own `finally`, in-process (a second `playwright-cli`
# spawn for it cost 0.6s per script). The EXIT trap below only covers the case
# where the script died mid-scenario and the `finally` never ran.
#
# Two knobs relax that:
#   KEEP_SESSION=1       leave the session signed in after the script -- for looking
#                        at a page by hand, and what `gate.sh --only` sets so the
#                        next iteration of the same test skips the sign-in.
#   MDL_SESSION_REUSE=1  what gate.sh sets for a full run: scripts leave the session
#                        signed in, open_app reuses it when it belongs to the same
#                        TEST_USER, and the gate signs out once at the end. Five
#                        tests then pay for one sign-in instead of five sign-outs
#                        and five sign-ins.
# FRESH_SESSION=1 overrides both: every open_app starts from the login page.
_MDL_RELEASE=1
if [ "${KEEP_SESSION:-0}" = "1" ] || [ "${MDL_SESSION_REUSE:-0}" = "1" ]; then _MDL_RELEASE=0; fi
_MDL_REUSE=$((1 - _MDL_RELEASE))
[ "${FRESH_SESSION:-0}" = "1" ] && _MDL_REUSE=0
_release_session() {
  local status=$?
  kill "$_MDL_WATCHDOG" 2>/dev/null || true
  if [ "$_MDL_TIMED_OUT" = "0" ] && [ -f "$_MDL_TIMEOUT_FLAG" ]; then
    # The sleeper fired but `set -e` ended the script on the killed child before
    # the TERM trap could run: same failure, same message.
    echo "FAIL: test exceeded ${_MDL_LIMIT}s (SCRIPT_TIMEOUT): a browser call or a polling loop never returned." \
         "If the next test hangs too, the browser is stuck: playwright-cli close && playwright-cli open" >&2
    _MDL_TIMED_OUT=1
    status=124
  fi
  rm -f "$_MDL_TIMEOUT_FLAG"
  # A scenario that ran to its `finally` has already signed out. Only a scenario
  # cut short by the watchdog has not -- and then the browser that just hung is
  # the one being asked, so the request is bounded rather than trusted.
  if [ "$_MDL_TIMED_OUT" = "1" ] && [ "$_MDL_RELEASE" = "1" ] && [ -n "$TEST_PASSWORD" ]; then
    _mdl_bounded 5 playwright-cli run-code \
      "async () => { try { await page.evaluate(() => { if (window.mx && mx.logout) mx.logout(); }); } catch (e) {} return true; }" || true
  fi
  return $status
}
trap _release_session EXIT

# The same sign-out, callable from a runner: gate.sh ends a MDL_SESSION_REUSE run
# with it. A no-op where nothing is signed in.
release_session() {
  _mdl_bounded 10 playwright-cli run-code \
    "async () => { try { await page.evaluate(() => { if (window.mx && mx.logout) mx.logout(); }); await page.waitForSelector('#usernameInput, input[name=username]', {timeout: 5000}); } catch (e) {} return true; }" || true
}

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
    printf '  const RELEASE = %s;\n' "$_MDL_RELEASE"
    printf '  const REUSE = %s;\n' "$_MDL_REUSE"
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
    printf '}\n'
  } > "$code_file"

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
#
#   [ "$(field "$result" confirmed)" = "true" ] || fail "..."
#
# Booleans come back as JSON spells them, `true`/`false`, and null as `null`.
# Python's own str() gave `True` here for a long time, so every test had to compare
# against "True" -- and one that compared against "true" could never pass, which
# looked exactly like a broken feature. Strings, numbers, lists and objects come
# back as JSON too, except that a plain string is unquoted.
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
print(value if isinstance(value, str) else json.dumps(value))
"
}

# Read several fields in one process: `fields "\$result" a b c` prints one line per
# key, in order, in the same form as field(). Each field() call costs a Python
# start (~0.03s); a test that reads six keys reads them here once.
#
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
