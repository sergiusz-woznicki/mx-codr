---
step: catalog
level: off
check: mxcli
key: document
---

# CONV003 — page names should end with a type suffix (_NewEdit, _View, _Overview, _Select, _Details, _Dashboard)

## What it checks
mxcli lint rule CONV003 (PageNamingSuffix): Page names should end with a type suffix (_NewEdit, _View, _Overview, _Select, _Details, _Dashboard). Off: Page names follow the harness's own names (OrderOverview, Order_Detail), not this suffix list. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
