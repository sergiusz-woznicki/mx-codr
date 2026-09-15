#!/usr/bin/env bash
# covers: InvoiceDesk.ACT_TestData_Reset
#
# Runs first (alphabetical order) and puts the data back to its seeded state, so
# every test after it starts from the same 3 customers / 10 invoices.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

before="$(oql_count Invoice)"

result="$(scenario '
  await open_app();
  await dismiss_dialog();
  await page.click(".mx-name-btnNewInvoice");
  await page.waitForSelector(".mx-name-txtNumber");
  await fill("txtNumber", "NOISE-" + Date.now());
  await fill("txtAmount", "1");
  await pick_combo("cmbCustomer", "Northwind Traders");
  await page.click(".mx-name-btnSave");
  await page.waitForSelector(".mx-name-txtNumber", {state: "detached", timeout: 15000});
  await menu("Reset demo data");
  // The menu item itself says "Reset", so /reset/ would match before the message
  // exists; the phrase below occurs only in the message.
  const text = await await_message(/demo data reset/i);
  await dismiss_dialog();
  return {confirmed: /demo data reset/i.test(text)};
')"

[ "$(field "$result" confirmed)" = "true" ] || fail "no confirmation message after the reset"

invoices="$(oql_count Invoice)"; customers="$(oql_count Customer)"
[ "$invoices" = "10" ] || fail "expected exactly 10 invoices after reset, found $invoices (was $before)"
[ "$customers" = "3" ] || fail "expected exactly 3 customers after reset, found $customers"

echo "OK: reset restored 10 invoices / 3 customers (was $before)"
