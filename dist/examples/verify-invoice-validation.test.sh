#!/usr/bin/env bash
# covers: InvoiceDesk.VAL_Invoice
#
# Saving an empty invoice is refused: the popup stays open, all three messages
# appear, and nothing is written.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

before="$(oql_count Invoice)"

result="$(scenario '
  await open_app();
  await dismiss_dialog();
  await page.click(".mx-name-btnNewInvoice");
  await page.waitForSelector(".mx-name-txtNumber");
  await page.click(".mx-name-btnSave");
  await page.waitForTimeout(1200);
  const text = await page_text();
  const stillOpen = await page.locator(".mx-name-txtNumber").count() > 0;
  // The customer rule reports through a Show message, whose modal covers Cancel.
  await dismiss_dialog();
  await page.click(".mx-name-btnCancel");
  await page.waitForSelector(".mx-name-txtNumber", {state: "detached", timeout: 10000});
  return {
    stillOpen,
    number: /invoice number is required/i.test(text),
    amount: /greater than zero/i.test(text),
    customer: /customer this invoice belongs to/i.test(text)
  };
')"

[ "$(field "$result" stillOpen)" = "True" ] || fail "the popup closed on an invalid invoice — validation did not block the save"
[ "$(field "$result" number)" = "True" ] || fail "missing the 'invoice number is required' message"
[ "$(field "$result" amount)" = "True" ] || fail "missing the amount validation message"
[ "$(field "$result" customer)" = "True" ] || fail "missing the customer validation message"
[ "$(oql_count Invoice)" = "$before" ] || fail "invoice count changed despite failed validation"

echo "OK: invalid invoice refused with all three messages, nothing stored"
