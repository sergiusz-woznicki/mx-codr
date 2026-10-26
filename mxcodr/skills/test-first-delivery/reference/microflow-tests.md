# Microflow tests: optional -- suggest them in the final report

A browser test proves a person can do the thing, and it is the only test a check asks for. A
microflow test (`tests/<feature>.test.mdl`, skill `test-microflows`) is never an obligation: no check
requires one, and none is the way out of a finding. Measured over 31 sessions (2026-10-16), one caught a
single logic bug, which a browser test caught too; its red runs were mostly a wrong test or the system
session it runs in, and twice an agent chasing one made a correct microflow worse.

So do not write them while building. End the final report with **Suggested microflow tests**: the
logic no screen reaches, for the person to decide on. The gate's DONE lists the ones it found (REQ02,
TIMER01); add the kinds no checker sees:

| Kind | What a test would assert |
|---|---|
| **What a scheduled event or background job picks**: reminders, expiry, clean-up | the records it must take (overdue, unpaid) and the ones it must leave (paid, already reminded, not yet due) |
| **The after-startup seed** | running it twice leaves the same number of records |
| **A rule with many edge cases behind one screen** | the edges the browser test skips: exactly on a limit, the day itself, the touching time slot |
| **A data rule no requested screen reaches**: a format, uniqueness, a bound on stored data | the bad value refused and a good one saved, by calling the microflow that saves or validates -- never an edit page built only to test it |

Calculations, status changes, limits and messages a person sees are the browser test's job: assert the
number, the status and the message on the page.

The rest of this page is for whoever writes one anyway, now or later.

## Before you touch a microflow for a red microflow test

Read the test first. The usual cause is the test: an object it created and did not link, a value it
read back in the same request, a parameter name. Change the microflow only when the test is right and
the browser shows the same wrong behaviour.

The test runs in a system session, like an after-startup microflow and a scheduled event:
`[%CurrentUser%]` in a microflow throws there. Use `$currentUser` (empty in a system session) in the
microflow, not a workaround in the test.

## Write it

```sql
mdl 1;

/**
 * @test The reminder job picks an unpaid invoice that is a day overdue
 * @expect $picked = true
 */
$invoice = create Sales.Invoice (Number = 'INV-T-1', DueDate = addDays([%CurrentDateTime%], -1), IsPaid = false);
commit $invoice;
$picked = call microflow Sales.SUB_Invoice_NeedsReminder(Invoice = $invoice);
/

/**
 * @test The reminder job leaves a paid invoice alone
 * @expect $picked = false
 */
$invoice = create Sales.Invoice (Number = 'INV-T-2', DueDate = addDays([%CurrentDateTime%], -1), IsPaid = true);
commit $invoice;
$picked = call microflow Sales.SUB_Invoice_NeedsReminder(Invoice = $invoice);
/
```

- One behaviour per block, ending with `/`. The `@test` line says it in the user's words.
- Every block asserts something, with `@expect` or `@throws`. The gate runs with
  `--require-assertions`, so a block with no assertion fails.
- A refusal is asserted on a microflow call: `@throws` then `$Saved = call microflow Mod.SUB_Member_Save(...)`.
  A `commit` written straight in the block that breaks a validation rule is reported as `ERROR`, not
  caught by `@throws` (measured on mxcli 0.28, Mendix 11.12).
- A block makes its own data and commits it. It never relies on what the seed or another block
  left behind.
- `./mxcli check tests/<feature>.test.mdl -p <app>.mpr` reads the file in about a second. Run it
  before the gate.

## Run it

The **full** gate runs every `*.test.mdl` once the rest of the gate is green (MFTEST01, a warning:
red never holds DONE). It runs them on a copy of the project, so the app you are working on is never
touched. A failure names the block, the expected value and the actual value. The whole output is in
`.mxcli/microflow-tests.txt`. Never run `mxcli test` by hand: it injects a test module into the
project and rewrites `javasource` while it runs.
