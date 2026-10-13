---
step: layout
level: block
check: layout_rules/list_tabs.cjs#listTabsFindings
key: document
---

# TABS02 — stacked lists go in tabs

## What it checks
A page with two or more lists (data grid, list view, gallery) one under another puts them in tabs, one list a tab, so nobody scrolls past one list to find the next. Lists side by side in one row, and lists already in tabs, pass.

## Fix
In the finding.

## Local
# level: block
# except: Module.Page   # why
