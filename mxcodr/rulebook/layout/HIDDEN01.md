---
step: layout
level: block
check: layout_rules/hidden.cjs#hiddenWidgetFindings
key: none
---

# HIDDEN01 — no never-shown widget

## What it checks
No widget has `Visible: [false]`: no one sees it, and a test reading through it proves nothing.

## Fix
Remove it; prove access with `oql_count` in the test.

## Local
# level: block
