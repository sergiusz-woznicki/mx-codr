---
step: catalog
level: off
check: mxcli
key: document
---

# CONV016 — avoid entity event handlers; use explicit microflow calls instead

## What it checks
mxcli lint rule CONV016 (NoEventHandlers): Avoid entity event handlers; use explicit microflow calls instead. Off: EVENT01-04 already checks this in the gate. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
