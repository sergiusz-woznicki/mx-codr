---
step: layout
level: block
check: layout_rules/accounts.cjs#accountFindings
key: none
---

# ACCOUNT03 — every signing-in role has Administration.User

## What it checks
With login: every role that logs in includes the Administration module's User role, and some role can manage users.

## Fix
Add Administration.User to the user role.

## Local
# level: block

