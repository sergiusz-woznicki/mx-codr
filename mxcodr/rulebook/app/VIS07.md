---
step: tests
level: block
check: scenario-helpers.js#visual_findings
key: none
---

# VIS07 — amounts look alike

## What it checks
Measured at the end of every test: a data grid column whose numbers carry different decimals ("688.8", "1228.77", "5535"), or a page that shows one amount with a thousands separator and another of 1000 or more with decimals and none ("50,000.00" beside "19190.829"). One kind of value in two formats.

## Fix
`formatDecimal($V, '#,##0.00')`

## Local
# level: block
