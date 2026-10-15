---
step: catalog
level: off
check: mxcli
key: document
---

# CONV002 — avoid default values on entity attributes; set them in microflows instead

## What it checks
mxcli lint rule CONV002 (NoEntityDefaultValues): Avoid default values on entity attributes; set them in microflows instead. Off: The apps use defaults on purpose (a new order starts as Draft). Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
