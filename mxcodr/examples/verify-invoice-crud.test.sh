#!/usr/bin/env bash
# covers: InvoiceDesk.Invoice_NewEdit, InvoiceDesk.ACT_Invoice_Save
# An invoice created from the list is stored with the values typed.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

number="TEST-$$"

scenario '
  await open_app();
  await dismiss_dialog();
  await page.click(".mx-name-btnNewInvoice");
  await page.waitForSelector(".mx-name-txtNumber");
  await fill("txtNumber", "'"$number"'");
  await fill("txtAmount", "42");
  await pick_combo("cmbCustomer", "Northwind Traders");
  await page.click(".mx-name-btnSave");
  // A save that passes validation closes the popup; one that fails leaves it open
  // with messages, and this wait is what tells the two apart.
  await page.waitForSelector(".mx-name-txtNumber", {state: "detached", timeout: 15000});
  return {saved: true};
' > /dev/null

await_row Invoice "InvoiceNumber = '$number'" || fail "invoice $number was not stored"
[ "$(oql_value Invoice Amount "InvoiceNumber = '$number'")" = "42" ] || fail "invoice $number stored without its amount"
[ "$(oql_value Invoice InvoiceNumber "InvoiceNumber = '$number'")" = "$number" ] || fail "invoice number not stored as typed"

echo "OK: $number created through the form and stored with its values"
