---
step: layout
level: warn
check: layout_rules/spacing.cjs#check
key: none
---

# ALERT01 — an alert class on a container, not on inline text

## What it checks
Points out an alert or card style put on a plain text, where it renders badly. Put it on a container around the text.

## Fix
`Class: 'alert alert-info'` on a container.

## Local
# level: warn

