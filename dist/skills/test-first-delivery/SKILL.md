---
name: test-first-delivery
description: "The order of work when building or changing app functionality — failing test first, then the implementation, then green, and nothing counts as done until the whole suite passes. Use before adding, changing or fixing any feature in a Mendix app, including bug fixes."
---

# Test-first delivery

This skill is not about how to write a test — [test-app](../../../.ai-context/skills/test-app/SKILL.md) has
the browser vocabulary, [test-microflows](../../../.ai-context/skills/test-microflows/SKILL.md) the logic
tests, and [verify-with-oql](../../../.ai-context/skills/verify-with-oql/SKILL.md) the data assertions.

It is about **when**, and about what "finished" means. A feature that has been
built but not proven is not finished, and the person who finds out is the user,
clicking through the app.

## The loop, in one screen

Sessions read the top of a file, so the whole discipline is here; the sections below
are the detail behind each line.

```bash
# 0. say what "working" means, in the user's words
# 1. write tests/verify-<feature>.test.sh with a `# covers:` header -- ONE scenario call
# 2. RUN IT AND WATCH IT FAIL -- the step that proves the test can fail at all
bash tests/gate.sh --only <feature> --boot-if-needed
#    (the gate records that red run in .mxcli/red-first/; that record is the proof,
#     so there is no need to break the feature later to see the test notice)
# 3. implement the smallest MDL that satisfies the criterion
./mxcli check <script>.mdl -p <app>.mpr --references && ./mxcli exec ...
# 4. iterate on that ONE script until green (~2s a run) -- always through the gate,
#    never `bash tests/verify-x.test.sh`: the gate keeps the browser and the session
#    warm and it is where the timeout and the facts-on-failure live
bash tests/gate.sh --only <feature>
# 5. the whole gate: suite + mx check + lint + coverage, ends in DONE or NOT DONE
bash tests/gate.sh
```

Non-negotiable, in order of how often they get skipped:

1. **The test fails before the implementation exists.** A test that has never been red
   may assert nothing at all; you cannot tell by reading it.
2. **Never edit a test to make it pass.** Wrong test means the criterion was wrong —
   change it as its own visible step, and say so.
3. **Iterate on one script, never the whole suite.** A red loop is ~2s per run; a suite
   is ~25s, and one session spent 8 of its 10 minutes of test time on suite reruns.
4. **Done is the full gate printing `DONE`**, quoted as output — not "should work".

## When to Use This Skill

Use it whenever you are about to change what the app *does*:

- Adding a page, a button, a microflow, an action
- Changing behaviour of something that already exists
- Fixing a bug
- Being asked to "just quickly" add something — that is when the step gets skipped

Not for pure refactors that change no behaviour, and not for model-only chores
(renames, folder moves, documentation).

## The loop

### 0. State the acceptance criterion

One sentence, in the user's words, describing what they will see working:

> "Clicking Send reminder on an overdue invoice bumps its reminder count and tells
> me it was sent."

No criterion means no test, and no test means no work. If the request is too vague
to write one, ask — one question now is cheaper than a feature built against the
wrong idea.

### 1. Write the failing test first

One script per feature, in the app's `tests/` directory, named to the convention
`mxcli playwright verify` expects:

```
tests/verify-<feature>.test.sh
```

Every script starts with a `covers:` header naming the model elements it exercises.
`check_test_coverage.py` reads it (see *Check it* below), so this is the line that
makes "everything is tested" a fact rather than a claim:

```bash
#!/usr/bin/env bash
# covers: InvoiceDesk.Invoice_Overview, InvoiceDesk.ACT_Invoice_SendReminder
set -euo pipefail
```

### 2. Run it and watch it fail

```bash
bash tests/gate.sh --only <feature>
```

**Quote the failure, and read it — the line is self-contained.** `mxcli playwright
verify` reprints only the last stderr line of a script, so `lib.sh` folds the whole
cause into it: the Playwright error, the locator it waited for, the URL it was on and
who was signed in.

```
FAIL: browser scenario failed: Error: page.click: Timeout 8000ms exceeded. | Call log: |
- waiting for locator('.mx-name-btnDoesNotExist') [on http://localhost:8081/index.html, signed in as demo_administrator]
```

Read that instead of re-running the script by hand, screenshotting, or probing the
runtime — those rounds are the expensive part of a red loop, not the test.

**This red run is the proof that the test can fail, and the gate keeps it.** The
first failing `--only` run of a script writes `.mxcli/red-first/<script>`. Mutation
testing — breaking the feature on purpose to see the test go red — is worth doing
for exactly one kind of test: one that went green without ever having been red here.
The gate names such a test when it first passes (`went green without ever being red
here`). For every other test the record already answers the question; one session
spent 15 minutes breaking every feature for every test, and proved nothing the red
runs had not. When you do mutate, run the mutant through `bash tests/gate.sh --only
<feature>` like any other run, and undo the mutation before going on.

 This is the only step that catches a test
asserting nothing: a test written after the implementation, or one that checks a
selector exists without checking what it renders, passes just as happily against a
broken app. If it goes green here, the test is wrong — fix the test, not the app.

It also has to fail **for the right reason**. A reset test in this app first failed
on "found 14 invoices" instead of on the missing menu item — because the helper that
clicked the menu swallowed the JavaScript error and carried on. `scenario()` cannot
swallow one: a throw in the body is re-raised carrying the page and the signed-in
user, and a run that returned no result at all — a closed browser, most often —
fails with what playwright-cli actually said. If you call `playwright-cli` directly
instead, check its output, because a throw inside the page prints an error and exits 0:

```bash
playwright-cli eval "() => { ... ; return true }" | grep -q true || fail "could not click"
```

### 3. Implement

The smallest MDL that satisfies the criterion. Validate before applying, as always:

```bash
./mxcli check mdlsource/<script>.mdl -p <app>.mpr --references
./mxcli exec  mdlsource/<script>.mdl -p <app>.mpr
```

### 4. Run that test until it is green

```bash
bash tests/gate.sh --only <feature>          # one script, warm browser, ~2-3s
```

Run **one script**, not the suite, while you iterate. This is the single biggest
lever on a red loop: one session spent **8.3 of its 9.7 minutes of test time on ten
full-suite reruns** while debugging one script, because that script only failed in
the suite. If a test passes alone and fails in the suite, that is a test-isolation
bug — sign-in identity, or data left behind — and it is fixed in `tests/lib.sh`, not
by rerunning the suite until it makes sense.

Under the hood it is `mxcli playwright verify <script> --keep-open --timeout 90s`.
Three things decide how long the loop takes:

- `--keep-open` leaves the browser warm, so the next run skips the Chromium launch;
  under `--only` the session stays signed in too, so the next run skips the sign-in.
- `--timeout 90s` caps a script instead of the 2m default, and `tests/lib.sh` fires
  its own watchdog 5s earlier, so a hung browser call ends with a `FAIL:` line that
  names the cause rather than a bare kill. A failing test sits out its waits, which
  is why a red suite measured 8m55s against 2m19s green — during development the
  failing case is the normal case.
- Keep the app up in another terminal with hot reload, so a page or microflow
  change needs no restart:

  ```bash
  bash tests/gate.sh --boot-if-needed
  ```

  That starts the app the way this project starts it, which is not always
  `./mxcli run --local --watch` -- that command deadlocks on some machines, and
  where the installer had to choose another way, `tests/harness.env` records it in
  `MDL_BOOT_COMMAND` (the file exists only on such machines; do not go looking for
  it elsewhere). When the gate says the model changed after the runtime started,
  `bash tests/gate.sh --restart` stops this project's runtime, boots it again and
  runs the gate -- one command, not a pgrep-and-kill improvisation.

  **Check which loop you are in before planning around it.** With `--watch` and a
  live model, only entity and association changes need a reboot and everything else
  hot-applies in about a second. Where the runtime serves a *built deployment* there
  is no hot reload at all: every model change costs a rebuild and a restart, one to
  two minutes. The red-green loop still works and `--only <feature>` is still the
  right command, but batch your model edits instead of making them one at a time,
  and trust the gate's stale-model warning to tell you when you are measuring an old
  build.
  A restart per iteration is 30-60s that this removes.

### 5. Run the whole suite, from a known state

```bash
bash tests/gate.sh                  # the whole suite, once
```

A feature that reddens an existing test is not done. One suite run at the end, not
one per iteration: the suite is ~21s, but each shell round trip in a session costs
3–5s on top of whatever it runs, so the count of commands matters more than their
cost. This step is not optional, because "my change could not possibly have affected
that" is exactly the belief regressions live in.

Scripts run in **alphabetical order**, and every test that creates rows leaves them
behind. Two conventions keep the suite honest:

- `tests/verify-000-reset.test.sh` runs first and puts the data back to its seeded
  state through the app itself (a menu action calling a reset microflow, in this
  app). Every run starts from the same rows.
- Anything that asserts **exact counts** is named `verify-001-…`, so it runs right
  after the reset — the only moment those counts are true.

Two rules the harness enforces, because a green suite can otherwise be measuring the
wrong page or a signed-out session:

- **Prove the page arrived.** `menu('Invoices', 'invoiceGrid')` waits for the widget that
  proves arrival. A nav click that silently does nothing otherwise leaves every later
  assertion measuring the *previous* page — which reads as a defect that does not exist.
  With one argument, `menu()` still checks that *something* happened (page changed, or a
  dialog opened), because a menu item can be a microflow action rather than a page.
- **`page.goto` is how a journey starts, never how it recovers.** A mid-scenario reload
  wipes client state, hides carry-over between steps, and with security on it silently
  signs the session out — after which the suite carries on as if navigation worked.
  `open_app()` does the one legitimate goto; `reopen_app()` starts a fresh journey on
  purpose. Any other goto throws.

A Mendix *Show message* renders a modal with an OK button, and it swallows the next
click. Dismiss it (`dismiss_dialog` in `tests/lib.sh`) before acting again; reuse the
helpers there — `open_app`, `fill`, `pick_combo`, `row_action`, `menu`,
`await_message`, `dismiss_dialog`, `page_text` — rather than reinventing them per test.

Three habits that quietly cost time or hide a failure:

- **Never `page.waitForTimeout(1500)` to wait for a message.** `const text = await
  await_message(/reminder sent/i)` returns the moment the text is on screen and, when
  it never comes, fails saying what the page showed instead. A fixed pause is either
  too long every time or too short on a slow run. Match the *message*, not a word
  the page already shows — a button captioned "Unpaid" satisfies `/unpaid/i` before
  the message exists; `/has \d+ unpaid invoice/i` does not.
- **Booleans come back as `true`/`false`.** `field "$result" ok` prints JSON:
  `[ "$(field "$result" ok)" = "true" ]`. Read several keys in one call with
  `fields "$result" a b c` (one line each, in order).
- **Put both values in the `fail` message.** `fail "expected 4 customers, found $n"`
  — the raw compared values, so a wrong assertion (a stray space, a number as a
  string) is visible from the one line the runner reprints.

### 6. Only now is it done

Done means all four of these — and one command reports all four, because four
separate calls cost four round trips:

```bash
bash tests/gate.sh
```

```
== gate
   tests: Total: 9  Passed: 9  Failed: 0  Time: 19.5s
   mx check: 0 errors
   lint: 53 issues: 0 errors, 31 warnings, 22 info
   coverage InvoiceDesk: PASS  11/11 elements covered by 9 test script(s)
   DONE — every check passed
```

- [ ] The new test passes
- [ ] The whole suite passes
- [ ] `mx check` reports 0 errors
- [ ] `./mxcli lint -p <app>.mpr` reports 0 errors for your module
- [ ] Every page and `ACT_` microflow is covered (the gate runs the checker)

Never report a feature as working on the strength of having written it. "Should
work" is not a result; paste what the runner printed.

## Write it as one scenario

A test costs one process launch per browser call — **0.14s** each on a warm
machine, 0.66s measured cold, before any browser work happens. A test written as
twenty helper calls pays that twenty times over, and each call also re-resolves the
page; `verify-escalate` used to take 35.6s and roughly half of that was spawning.

So: **one `scenario` per test.** The whole flow runs in a single process, and the
assertions happen in the shell afterwards, where `mxcli oql` costs ~0.03s.

```bash
source "$(dirname "$0")/lib.sh"

number="TEST-$$"

scenario '
  await open_app();
  await page.click(".mx-name-btnNewInvoice");
  await page.waitForSelector(".mx-name-txtNumber");
  await fill("txtNumber", "'"$number"'");
  await pick_combo("cmbCustomer", "Northwind Traders");
  await page.click(".mx-name-btnSave");
  await page.waitForSelector(".mx-name-txtNumber", {state: "detached"});
  return {saved: true};
' > /dev/null

await_row Invoice "InvoiceNumber = '$number'" || fail "invoice $number was not stored"
```

Measured on this suite: **2m19s → 21s green** for 9 scripts, same coverage —
1.4–3.2s per script, `mxcli playwright verify` itself costing 1.7s per invocation
and `mxcli oql` 0.02s per assertion.

Rules that keep it that way:

- **Assert on the database, not the screen**, wherever the database can answer.
  `await_row` polls with OQL and costs nothing; a grid assertion depends on paging
  and sort order and belongs only in the test whose job is rendering.
- **One scenario, one purpose.** A scenario that throws reports one failure for the
  whole flow, so keep the flow short enough that the message is unambiguous, and
  return named fields (`{header: true, missing: [...]}`) rather than one boolean.
- **Fill then blur.** Mendix commits an input on blur; `fill()` presses Tab for
  this reason. A fill followed straight by a click on Save can save the old value.
- **Let it fail fast.** The scenario sets an 8s action timeout, not Playwright's
  default 30s, because during development the failing case is the normal case.
- **Say who you are.** The runner can reuse one browser across scripts, so a test
  that assumes "not signed in" is really testing whoever the previous script signed
  in as. A test for a different user sets `TEST_USER`/`TEST_PASSWORD` before sourcing
  `lib.sh`, and `open_app` signs the old session out first. Sign out — do not just
  clear cookies: the server-side session survives that and the next sign-in hits the
  runtime's session cap, reported in the browser as a bare "Sign in failed".

## The rules that make it bite

**Never edit a test to make it pass.** If the test is wrong, then the acceptance
criterion was wrong — say so explicitly, agree the new criterion with the user, and
change the test as its own visible step. Silently relaxing an assertion until it
goes green converts a failing feature into a passing test suite, which is worse
than having no tests.

**Never delete, skip or comment out a red test to finish.** A red test is the work
not being done. Report it red rather than making it disappear.

**A bug fix gets a test too**, and in the same order: a test that fails on the bug,
then the fix, then green. Otherwise the bug comes back and nothing notices.

**Assert on content, not existence.** `document.querySelector('.mx-name-x') !== null`
passes on an empty grid, a broken data source and a page rendering an error. Assert
row counts, text, and the data behind it:

```bash
mxcli oql -p <app>.mpr --json "SELECT ReminderCount FROM InvoiceDesk.Invoice WHERE InvoiceNumber = 'INV-1001'"
```

**Touching an untested feature means writing its test first.** That is how coverage
grows without a big-bang backfill: the next change pays for it.

## Things a browser test alone will not catch

Two failure modes this app has already hit. Cover them deliberately:

- **Startup regressions.** An after-startup microflow that returns `false` aborts
  the runtime — the app never comes up. No page-loading test can see it, because
  there is no page. A feature that touches startup logic needs a test that
  **restarts** the app and asserts it came back.
- **Idempotence.** Seeding, imports and anything that "creates if missing" must be
  tested across a restart: run it twice, assert the second run changed nothing.

## Parallelise facts, never the app

Three shell calls asking three questions cost more than the questions: a call has a
~1.9s median in an agent session, the queries inside it 0.02s. So the harness asks
everything at once, in parallel:

```bash
bash tests/orient.sh        # ~0.3s: structure, security, navigation, tests + covers, coverage, lint, app state
bash tests/diagnose.sh Invoice demo_customer   # ~0.2s: row counts, sessions, access rules, associations, runtime errors
```

Reach for `orient.sh` before building. `diagnose.sh` you rarely need to run yourself:
`gate.sh` runs it for you whenever a test fails, and prints the facts under the
failure. It also warns when the model changed after the runtime started — security
and entity changes do not hot-apply, and a stale runtime fails a correct fix — and
names the fix: `bash tests/gate.sh --restart`. `docs/brain/`, where it exists, is
still where the *decisions* live; these report state only.

`gate.sh` does the same internally: `mx check`, lint and coverage need neither the app
nor the browser, so they run while the suite runs (~37s serial becomes ~27s), and with
`--boot-if-needed` they run while the runtime is still booting.

**Tests themselves never run in parallel.** One runtime, one database, one browser:
`verify-000-reset` rewrites the shared data every other script depends on, the `001`
tests assert exact counts, and the licence caps concurrent sessions. Isolation would
mean one app instance per lane — 30s+ of boot each — to turn a 27s suite into maybe
15s, while adding a class of flakiness that costs far more to diagnose.

**If you fan out subagents, only one may touch the app.** Running tests, executing
MDL and signing in all mutate state that is global to the runtime, and two agents
doing it at once produce failures that belong to neither. Reads, static checks and
drafting MDL are safe to parallelise; anything that writes is one lane.

## Session limits on a developer licence

A developer/trial runtime caps concurrent sessions — measured on this app, the 7th
live session was refused, and the runtime logged 60 refusals in one evening:

```
WARNING - Core: Maximum number of sessions exceeded! (You are currently using a trial license)
```

It reaches the browser as a sign-in that never completes, so it reads as a broken
feature rather than a licence limit. Everything counts towards the cap: each test
browser, each developer tab on the app, each CLI login, until it times out.

Credentials live in **`tests/credentials.env`**, not in `lib.sh` — the password is not
in the `.mpr` and `SHOW DEMO USERS` reports names and roles only, so nothing can
discover it. The **user** belongs there too: the canonical tests drive the staff
screens, and which role may open those is a per-app decision. Get it wrong and five
tests go red the moment security is switched on, all of them really saying "this user
cannot see the button".

```
TEST_USER=demo_collector
TEST_PASSWORD=SomePass12345
TEST_PASSWORD_demo_customer=OtherPass12345
```

A refused sign-in fails in about a second, quoting what the login page said, rather
than waiting out the 20s page timeout.

An app with `Security Level: Off` needs no file at all; if one is present anyway, the
first scenario says so rather than waiting 20s for a login page that cannot appear.

The harness covers its own share and names the rest:

- `open_app` signs the previous session out before signing in, so scripts take one
  session in turn rather than stacking.
- `lib.sh` signs out when the script ends, so a warm `--keep-open` browser does not
  hold one between runs. `KEEP_SESSION=1` keeps it, for poking at a page by hand.
- A failing scenario appends the refusal to its failure line when the runtime logged
  one in the last two minutes.
- `gate.sh` lists who is already signed in, and stops before running the suite if the
  runtime has just refused a session (`ALLOW_BUSY_SESSION=1` overrides).

If tests fail on sign-in anyway: close the app's browser tabs, or restart the runtime,
which clears every session at once.

## Navigating with security off

With `Security Level: Off`, direct `/p/<PageName>` URLs redirect to the home page —
a test that navigates that way silently asserts against the wrong page. Click your
own named widgets instead (`.mx-name-*` comes from the widget name in MDL), and wait
for the client rather than sleeping a fixed number of seconds — `open_app` already
waits for `.mx-page`, and inside a scenario every wait is Playwright's:

```js
await page.waitForSelector('.mx-name-invoiceGrid');
```

Check the level before assuming: `./mxcli -p <app>.mpr -c "SHOW PROJECT SECURITY"`.

## Check it

```bash
python3 tools/mdl-checks/check_test_coverage.py . <Module>
```

Lists every page and `ACT_` microflow in the module and fails on any without a
`# covers:` line in some `tests/verify-*.test.sh`, and on any `covers:` naming an
element that no longer exists. (In this repo the checker is
`tests/skills/check_test_coverage.py`; `tools/mdl-checks/` is where `install.sh` puts
it in an installed project.)

## Validation checklist

- [ ] An acceptance criterion was stated before any code
- [ ] The test existed and **failed** before the implementation — for the right reason — and the failure was quoted
- [ ] Exact-count assertions run right after `verify-000-reset`
- [ ] The test is one `scenario` call, not a chain of browser calls
- [ ] The test declares a `# covers:` header naming real model elements
- [ ] No test was edited, skipped or deleted to reach green
- [ ] The whole suite was run, not just the new test
- [ ] `bash tests/gate.sh` ends in `DONE — every check passed`
- [ ] The red loop iterated on **one** script, not on the whole suite
- [ ] The result was reported as command output, not as a claim
