---
step: layout
level: block
check: layout_rules/page_top.cjs#currentUserFindings
key: none
---

# USER01 — who is signed in, top right, on every page

## What it checks
With login: every page shows who is signed in, top right. Pop-ups and the login page don't need it.

## Fix
A `snippetcall` of the current-user snippet, top right; the finding prints it.

## Local
# level: block

