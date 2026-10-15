---
step: catalog
level: off
check: mxcli
key: document
---

# CONV017 — avoid calculated attributes; use stored attributes updated by microflows

## What it checks
mxcli lint rule CONV017 (NoCalculatedAttributes): Avoid calculated attributes; use stored attributes updated by microflows. Off: A calculated attribute is used where the value must always be current (overdue). Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
