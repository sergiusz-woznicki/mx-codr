---
step: layout
level: block
check: layout_rules/list_tabs.cjs#listTabsFindings
key: document
---

# KPI01 — totals are tiles

## What it checks
A list over a view that always holds one row (totals with no group by) shows its figures as tiles, one card a figure, from a data view fed by a microflow, not as a table with one row.

## Fix
In the finding.

## Local
# level: block
# except: Module.Page   # why
