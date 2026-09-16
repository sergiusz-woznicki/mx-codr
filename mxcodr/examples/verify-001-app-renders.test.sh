#!/usr/bin/env bash
# covers: InvoiceDesk.Invoice_Overview, InvoiceDesk.Customer_Overview, InvoiceDesk.ACT_DemoData_Seed
# The app opens on the invoice list with header, seeded rows, columns, actions, and both menu items work.
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

{ read -r header; read -r columns; read -r seeded; read -r missing; read -r rows; read -r navigated; } \
  <<< "$(fields "$result" header columns seeded missing rows navigated)"
[ "$header" = "true" ] || fail "header snippet missing from the home page"
[ "$columns" = "true" ] || fail "a grid column is missing"
[ "$seeded" = "true" ] || fail "seeded rows are not rendering"
[ "$missing" = "[]" ] || fail "buttons missing from the invoice list: $missing"
[ "$rows" -gt 1 ] || fail "invoice grid rendered no data rows"
[ "$navigated" = "true" ] || fail "menu navigation failed"

echo "OK: home renders $rows rows, all columns and actions, both menu items navigate"
