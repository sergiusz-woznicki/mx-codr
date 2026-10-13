---
step: layout
level: block
check: layout_rules/grid_filters.cjs#missingFilterFindings
key: document
---

# GRID03 — grid columns have filters

## What it checks
Every column of a data grid that is bound to an attribute carries a filter in its own braces, on every grid in the app: overview and detail grids alike, whatever the row count today, because the rows grow with the app. Columns without an Attribute (buttons, custom content) are left alone.

## Fix
In the finding.

## Local
# level: block
# except: Module.Page   # why
