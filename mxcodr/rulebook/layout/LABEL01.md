---
step: layout
level: block
check: layout_rules/labels.cjs#rawLabelFindings
key: none
---

# LABEL01 — captions are words

## What it checks
No column caption or label is an attribute name such as `DueDate`.

## Fix
`Caption: 'Due date'`; one left out takes the attribute's name.

## Local
# level: block
