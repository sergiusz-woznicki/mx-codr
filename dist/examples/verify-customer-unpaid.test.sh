#!/usr/bin/env bash
# covers: InvoiceDesk.ACT_Customer_ShowUnpaid, InvoiceDesk.SUB_Invoice_CountUnpaid
#
# The customer list reports how many of a customer's invoices are still owed. The
# expected number comes from the invoices themselves, so the count is checked
# against the data rather than against a hard-coded figure.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

customer="Northwind Traders"
expected="$(oql "SELECT COUNT(*) AS Total FROM InvoiceDesk.Invoice AS i
  JOIN i/InvoiceDesk.Invoice_Customer/InvoiceDesk.Customer AS c
  WHERE c/Name = '$customer' AND (i/Status = 'Sent' OR i/Status = 'Overdue')" \
  | python3 -c "import json,sys; rows=json.load(sys.stdin); print(rows[0]['Total'] if rows else 0)")"

result="$(scenario '
  await open_app();
  await dismiss_dialog();
  await menu("Customers");
  await page.waitForSelector(".mx-name-customerGrid", {timeout: 15000});
  await row_action("customerGrid", "'"$customer"'", "btnUnpaid");
  await page.waitForTimeout(1200);
  const text = await page_text();
  await dismiss_dialog();
  return {reported: /unpaid/i.test(text), text: text.slice(-300)};
')"

[ "$(field "$result" reported)" = "True" ] || fail "no unpaid-count message shown for $customer"
printf '%s' "$(field "$result" text)" | grep -q "$expected" || fail "message does not report the expected count of $expected"

echo "OK: $customer reported $expected unpaid invoice(s)"
