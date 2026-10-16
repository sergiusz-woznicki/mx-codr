# Microflow tests: which logic gets one

A browser test proves a person can do the thing. It reaches a rule through one or two cases,
because each case costs a page visit. A microflow test (`tests/<feature>.test.mdl`, skill
`test-microflows`) calls the logic directly. Each case costs milliseconds, so it can cover
the edges a browser test skips. Write one **next to** the browser test, never instead of it,
whenever a feature has logic of one of these kinds:

| Kind | What to assert |
|---|---|
| **Calculations**: totals, VAT, discounts, rounding, money and unit formatting, scores | a typical value, zero, a negative, the rounding edge (x.xx5), a large value |
| **Status changes**: an order, request or ticket moving through its states | each allowed step; a skipped or backwards step refused **and** the status left unchanged; a final state that stays final |
| **Limits that refuse**: credit limit, capacity, stock not below zero, no double booking, a maximum per person | just inside the limit passes, exactly on it, just outside it refused with the message the user sees |
| **Dates and time windows**: due and overdue, cancel-before deadlines, end before start, opening hours | the day before, the day itself, the day after; month end; a start equal to the end |
| **What a background job picks**: reminders, expiry, scheduled clean-up | the records it must take (overdue, unpaid) and the ones it must leave (paid, already reminded, not yet due); a browser cannot fire a schedule |
| **Reading and making text**: a status from an outside system, a tax ID or IBAN check, a generated number (ORD/2026/0001) | the accepted spellings, a rejected one, the next number after the last, the format |
| **Startup data**: the after-startup seed | running it twice leaves the same number of records |

Skip it for logic a browser test already covers in full: plain save, delete, open a page, close
a page, a microflow that only calls another one.

## Shape the logic so it can be tested

Put the rule in a `SUB_` or `VAL_` microflow that takes values and returns a result: the amount,
the error text ('' when allowed), true or false. The `ACT_` behind the button calls it and shows
the result. A rule written inside an `ACT_` that opens pages cannot be called from a test.

## Write it

```sql
mdl 1;

/**
 * @test VAT is 21% of the net amount, rounded to cents
 * @expect $result = 26.04
 */
$result = call microflow Sales.SUB_Vat_Calculate(NetAmount = 124);
/

/**
 * @test An order over the credit limit is refused with the message the user sees
 * @expect $problem = 'The order exceeds the customer''s credit limit.'
 */
$customer = create Sales.Customer (Name = 'Limit Test BV', CreditLimit = 1000);
commit $customer;
$problem = call microflow Sales.VAL_Order_CreditLimit(Customer = $customer, OrderTotal = 1000.01);
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

Write the test before the microflow, the same way as a browser test. The **full** gate runs every
`*.test.mdl` once the rest of the gate is green (MFTEST01). It runs them on a copy of the
project, so the app you are working on is never touched. A failure names the block, the expected
value and the actual value. The whole output is in `.mxcli/microflow-tests.txt`. Never run
`mxcli test` by hand: it injects a test module into the project and rewrites `javasource` while
it runs.
