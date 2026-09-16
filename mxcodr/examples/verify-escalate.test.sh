#!/usr/bin/env bash
# covers: InvoiceDesk.ACT_Invoice_Escalate
# Escalate writes a seeded invoice off and explains what that means.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

number="INV-1003"   # seeded as Sent, so writing it off is a visible change

result="$(scenario '
  await open_app();
  await dismiss_dialog();
  await row_action("invoiceGrid", "'"$number"'", "btnEscalate");
  // Wait for the message itself, not a fixed pause: it returns the moment the
  // text is there, and fails saying what the page shows when it never comes.
  const text = await await_message(/escalated invoice/i);
  await dismiss_dialog();
  return {
    explained: /escalated invoice/i.test(text) && /collections/i.test(text)
  };
')"

status="$(oql_value Invoice Status "InvoiceNumber = '$number'")"
[ "$status" = "WrittenOff" ] || fail "expected status WrittenOff after escalation, got '$status'"
[ "$(field "$result" explained)" = "true" ] || fail "the escalation message does not explain what escalation means"

echo "OK: $number escalated to WrittenOff with the explanation shown"
