# Microflow tests: only where a browser cannot reach

A browser test proves a person can do the thing, and it is the test that counts. Measured over 31
sessions of the harness and of agents without it (2026-10-16), a microflow test (`tests/<feature>.test.mdl`,
skill `test-microflows`) caught one logic bug, and a browser test in the same session caught it too. Its red runs were
mostly a wrong test (a fixture missing an association, a value read back from memory) or the system
session it runs in. Twice an agent chasing a red microflow test made a correct microflow worse.

So write one only for logic no screen can drive:

| Kind | What to assert |
|---|---|
| **What a scheduled event or background job picks**: reminders, expiry, clean-up | the records it must take (overdue, unpaid) and the ones it must leave (paid, already reminded, not yet due) |
| **The after-startup seed** | running it twice leaves the same number of records |
| **A rule with many edge cases behind one screen**, when the browser test can afford only two of them | the edges the browser test skips: exactly on a limit, the day itself, the touching time slot |

Calculations, status changes, limits and messages a person sees are the browser test's job: assert the
number, the status and the message on the page. A microflow test never replaces one.

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
- A block makes its own data and commits it. It never relies on what the seed or another block
  left behind.
- `./mxcli check tests/<feature>.test.mdl -p <app>.mpr` reads the file in about a second. Run it
  before the gate.

## Run it

The **full** gate runs every `*.test.mdl` once the rest of the gate is green (MFTEST01). It runs
them on a copy of the project, so the app you are working on is never touched. A failure names
the block, the expected value and the actual value. The whole output is in
`.mxcli/microflow-tests.txt`. Never run `mxcli test` by hand: it injects a test module into the
project and rewrites `javasource` while it runs.
