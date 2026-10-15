---
step: catalog
level: off
check: mxcli
key: document
---

# CONV015 — avoid entity validation rules; use VAL_ microflows for validation instead

## What it checks
mxcli lint rule CONV015 (NoEntityValidationRules): Avoid entity validation rules; use VAL_ microflows for validation instead. Off: Entity validation rules are used where they are the simplest guard. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
