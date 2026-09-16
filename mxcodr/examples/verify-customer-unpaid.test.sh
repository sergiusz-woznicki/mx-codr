#!/usr/bin/env bash
# covers: InvoiceDesk.ACT_Customer_ShowUnpaid, InvoiceDesk.SUB_Invoice_CountUnpaid
# The customer list reports the unpaid invoice count the database holds.
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
  // Match the message, not a word the page already shows: the button itself is
  // captioned "Unpaid", so /unpaid/ would return before the message exists.
  const text = await await_message(/has \d+ unpaid invoice/i);
  await dismiss_dialog();
  return {reported: /unpaid/i.test(text), text: text.slice(-300)};
')"

[ "$(field "$result" reported)" = "true" ] || fail "no unpaid-count message shown for $customer"
printf '%s' "$(field "$result" text)" | grep -q "$expected" || fail "message does not report the expected count of $expected"

echo "OK: $customer reported $expected unpaid invoice(s)"
