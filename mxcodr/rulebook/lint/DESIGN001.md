---
step: catalog
level: off
check: mxcli
key: document
---

# DESIGN001 — entities should not have more than 10 attributes

## What it checks
mxcli lint rule DESIGN001 (Entity Attribute Count): Entities should not have more than 10 attributes. Off: An attribute count limit: not judged by the harness. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
