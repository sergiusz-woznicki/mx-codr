---
step: layout
level: block
check: layout_rules/accounts.cjs#accountFindings
key: none
---

# ACCOUNT01 — a Users menu item

## What it checks
With login: administrators have a "Users" menu item to manage accounts. It is required even when the request lists the menu or says "only": it is not an extra.

## Fix
Always required: `menu item 'Users'` showing `Administration.Account_Overview`.

## Local
# level: block

