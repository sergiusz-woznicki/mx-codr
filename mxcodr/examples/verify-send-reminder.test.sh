#!/usr/bin/env bash
# covers: InvoiceDesk.ACT_Invoice_SendReminder
# Send reminder raises ReminderCount and confirms on screen.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

number="INV-1001"   # seeded, guaranteed present by verify-000-reset

before="$(oql_value Invoice ReminderCount "InvoiceNumber = '$number'")"
[ "$before" = "no-such-row" ] && fail "seeded invoice $number is missing"
[ "$before" = "empty" ] && before=0

result="$(scenario '
  await open_app();
  await dismiss_dialog();
  await row_action("invoiceGrid", "'"$number"'", "btnRemind");
  const text = await await_message(/reminder sent for invoice/i);
  await dismiss_dialog();
  return {confirmed: /reminder sent for invoice/i.test(text)};
')"

after="$(oql_value Invoice ReminderCount "InvoiceNumber = '$number'")"
[ "$after" -gt "$before" ] || fail "ReminderCount for $number did not increase ($before -> $after)"
[ "$(field "$result" confirmed)" = "true" ] || fail "no reminder confirmation message shown"

echo "OK: reminder for $number raised the count $before -> $after and confirmed on screen"
