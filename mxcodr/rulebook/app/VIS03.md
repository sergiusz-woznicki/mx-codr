---
step: tests
level: warn
check: scenario-helpers.js#visual_findings
key: none
---

# VIS03 — no text is cut off by its box

## What it checks
No text is cut off because its box is too small. On a phone- or tablet-wide screen a data grid's cells count too, an ellipsis included.

## Fix
A fixed height on a text box, or a box class on inline text (`level: block` in ## Local blocks).

## Local
# level: warn

