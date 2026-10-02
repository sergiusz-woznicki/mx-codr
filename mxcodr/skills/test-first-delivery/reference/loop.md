# The loop, step by step

Detail behind [test-first-delivery](../SKILL.md): each step of the loop in prose, with a
worked example -- the criterion, the first red run and what its failure line says, keeping
the app up under `--watch`, and running the whole suite from a known state.

**0. State the acceptance criterion.** One sentence, in the user's words: *"Clicking
Send reminder on an overdue invoice bumps its reminder count and tells me it was
sent."* No criterion means no test, and no test means no work; if the request is too
vague for one, ask.

**1. Write the failing test first.** One script per feature, `tests/verify-<feature>.test.sh`,
starting with a `covers:` header naming the model elements it exercises — the gate's
coverage check reads it, so "everything is tested" is a fact rather than a claim:

```bash
#!/usr/bin/env bash
# covers: InvoiceDesk.Invoice_Overview, InvoiceDesk.ACT_Invoice_SendReminder
set -euo pipefail
```

A `verify-*.test.sh` is a browser test and only a browser test: the gate hands it to
`mxcli playwright verify`, which waits for a browser result, so a script that never
calls `scenario()` hangs for the full timeout. Logic with no screen in front of it goes
in a `tests/*.test.mdl` run with `mxcli test` (skill `test-microflows`) — an extra
check, not a substitute: the gate does not run those and coverage counts only
`verify-*.test.sh`.

**2. Run it and watch it fail.** `bash tests/gate.sh --only <feature> --boot-if-needed`.
Quote the failure and read it — the line is self-contained (the Playwright error, the
locator, the URL, who was signed in):

```
FAIL: browser scenario failed: Error: page.click: Timeout 8000ms exceeded. | Call log: |
- waiting for locator('.mx-name-btnDoesNotExist') [on http://localhost:8081/index.html, signed in as demo_administrator]
```

Read that instead of re-running by hand, screenshotting or probing the runtime. If the
test goes green here, the test is wrong — fix the test, not the app. It also has to
fail **for the right reason** (the missing button, not a stale row count). The gate
keeps this red run in `.mxcli/red-first/`; breaking the feature on purpose is only for
a test the gate flags as `went green without ever being red here`.

**3. Implement.** The smallest MDL that satisfies the criterion:
`./mxcli check mdlsource/<script>.mdl -p <app>.mpr --references`, then `./mxcli exec`.
A hook runs `bash tests/precheck.sh <script>.mdl` first (the build's own `mx check` on a
scratch copy, ~6s) and blocks an exec that would break the build or stop half-way -- do not
call it by hand; under Codex, where there is no such hook, call it yourself.

**4. Run that one test until it is green.** `bash tests/gate.sh --only <feature>` —
one script, warm browser, signed-in session, ~2-3s. Never the suite while iterating:
a test that passes alone and fails in the suite is a test-isolation bug (sign-in
identity, or a seeded row another test changed), not a reason to rerun the suite.

Keep the app up (`bash tests/gate.sh --boot-if-needed` starts it the way this project
starts it). Under `mxcli run --watch` **nothing needs a restart by hand**: logic and
pages reload in ~2s, entity, association, module and security changes apply through an
in-place runtime restart in ~10s, and the gate waits for the change to land. When the
gate says the model changed and nothing applied it: `bash tests/gate.sh --restart`. To
only stop the app (before `mxcli fix widgets`, say): `bash tests/gate.sh --stop`. Where
the runtime serves a built deployment there is no hot reload: batch model edits and
trust the gate's stale-model warning.

**5. Run the whole suite, from a known state.** `bash tests/gate.sh`, once, at the end.
Scripts run in alphabetical order and every test leaves its rows behind, so:
`verify-000-reset` runs first and restores the seeded data through the app; anything
asserting **exact counts** is `verify-001-…`. A test that changes a seeded row owns that row:
give it its own seeded row or one it creates, never a row another test reads. Two rules the harness enforces: `menu('Invoices', 'invoiceGrid')` proves
the page arrived (a silent nav click leaves every later assertion on the previous
page), and `page.goto` is how a journey starts, never how it recovers (`open_app()`
does the one goto, `reopen_app()` starts over, any other goto throws). Dismiss a *Show
message* dialog (`dismiss_dialog()`) before the next click; wait for a message with
`await_message(/reminder sent/i)`, never `page.waitForTimeout`.

**6. Only now is it done**, when `bash tests/gate.sh` prints `DONE — every check passed`.
Never report a feature as working on the strength of having written it. Paste what the
gate printed. When it prints `NOT DONE`, the cause of each failure is under the verdict.
