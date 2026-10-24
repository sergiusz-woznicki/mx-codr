---
step: layout
level: block
check: layout_rules/accounts.cjs#accountFindings
key: none
---

# ACCOUNT02 — a My account menu item

## What it checks
With login: everyone has a "My account" menu item to change their own password. It is required even when the request lists the menu or says "only": it is not an extra.

## Fix
Always required: `menu item 'My account'` calling `Administration.ManageMyAccount`.

## Local
# level: block

