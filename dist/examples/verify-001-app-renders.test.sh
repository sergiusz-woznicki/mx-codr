#!/usr/bin/env bash
# covers: InvoiceDesk.Invoice_Overview, InvoiceDesk.Customer_Overview, InvoiceDesk.ACT_DemoData_Seed
#
# One page load proves what three separate tests used to: the app opens on the
# invoice list with its header, the seeded rows render, the grid has every column
# and row action, and both menu items reach their page.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

invoices="$(oql_count Invoice)"; customers="$(oql_count Customer)"
[ "$invoices" = "10" ] || fail "expected exactly the 10 seeded invoices, found $invoices"
[ "$customers" = "3" ] || fail "expected exactly the 3 seeded customers, found $customers"

result="$(scenario '
  await open_app();
  await dismiss_dialog();
  await page.waitForSelector(".mx-name-invoiceGrid");
  const home = await page_text();
  const rows = await page.locator(".mx-name-invoiceGrid [role=row]").count();
  const buttons = {};
  for (const name of ["btnNewInvoice", "btnEdit", "btnRemind", "btnEscalate", "btnDelete"]) {
    buttons[name] = await page.locator(".mx-name-" + name).count();
  }
  await menu("Customers");
  await page.waitForSelector(".mx-name-customerGrid", {timeout: 15000});
  await menu("Invoices");
  await page.waitForSelector(".mx-name-invoiceGrid", {timeout: 15000});
  return {
    header: /InvoiceDesk/.test(home) && /Chase what is owed/.test(home),
    columns: ["Invoice", "Customer", "Amount", "Due", "Status", "Actions"].every(c => home.includes(c)),
    seeded: /Northwind Traders/.test(home) && /INV-100/.test(home),
    rows,
    missing: Object.keys(buttons).filter(k => buttons[k] === 0),
    navigated: true
  };
')"

[ "$(field "$result" header)" = "True" ] || fail "header snippet missing from the home page"
[ "$(field "$result" columns)" = "True" ] || fail "a grid column is missing"
[ "$(field "$result" seeded)" = "True" ] || fail "seeded rows are not rendering"
[ "$(field "$result" missing)" = "[]" ] || fail "buttons missing from the invoice list: $(field "$result" missing)"
[ "$(field "$result" rows)" -gt 1 ] || fail "invoice grid rendered no data rows"
[ "$(field "$result" navigated)" = "True" ] || fail "menu navigation failed"

echo "OK: home renders $(field "$result" rows) rows, all columns and actions, both menu items navigate"
