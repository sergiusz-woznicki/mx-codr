#!/usr/bin/env bash
# covers: InvoiceDesk.Customer_NewEdit
#
# A customer can be created from the customer list and lands in the database.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

name="Test Customer $$"
email="test$$@example.com"

scenario '
  await open_app();
  await dismiss_dialog();
  await menu("Customers");
  await page.waitForSelector(".mx-name-customerGrid", {timeout: 15000});
  await page.click(".mx-name-btnNewCustomer");
  await page.waitForSelector(".mx-name-txtName");
  await fill("txtName", "'"$name"'");
  await fill("txtEmail", "'"$email"'");
  await page.click(".mx-name-btnSave");
  await page.waitForSelector(".mx-name-txtName", {state: "detached", timeout: 15000});
  return {saved: true};
' > /dev/null

[ "$(oql_count Customer "Name = '$name'")" = "1" ] || fail "customer '$name' was not stored"
[ "$(oql_value Customer Email "Name = '$name'")" = "$email" ] || fail "customer stored without the email typed"

echo "OK: customer created through the UI and persisted"
