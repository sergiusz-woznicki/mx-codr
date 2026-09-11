#!/usr/bin/env bash
# covers: InvoiceDesk.ACT_Invoice_Escalate
#
# Escalate writes the invoice off and explains what that means. It acts on a
# seeded invoice that verify-000-reset restores, so no invoice is created here.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

number="INV-1003"   # seeded as Sent, so writing it off is a visible change

result="$(scenario '
  await open_app();
  await dismiss_dialog();
  await row_action("invoiceGrid", "'"$number"'", "btnEscalate");
  await page.waitForTimeout(1500);
  const text = await page_text();
  await dismiss_dialog();
  return {
    explained: /escalated invoice/i.test(text) && /collections/i.test(text)
  };
')"

status="$(oql_value Invoice Status "InvoiceNumber = '$number'")"
[ "$status" = "WrittenOff" ] || fail "expected status WrittenOff after escalation, got '$status'"
[ "$(field "$result" explained)" = "True" ] || fail "the escalation message does not explain what escalation means"

echo "OK: $number escalated to WrittenOff with the explanation shown"
