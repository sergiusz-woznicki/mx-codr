---
step: naming
level: warn
check: naming_rules.cjs#actionFindings
key: none
baseline: captions
---

# CAPTION02 — no activity keeps Mendix's default caption

## What it checks
No activity keeps the caption Mendix gives it by default, like "Retrieve Invoice" or "Commit object".

## Fix
As CAPTION01: warns until the first DONE, then blocks a microflow new or changed since.

## Local
# level: warn

