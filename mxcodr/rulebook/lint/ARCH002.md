---
step: catalog
level: off
check: mxcli
key: document
---

# ARCH002 — persistent entities should have microflows that handle data changes (create/update)

## What it checks
mxcli lint rule ARCH002 (Data Changes Through Microflows): Persistent entities should have microflows that handle data changes (create/update). Off: Changes through microflows: the security and paths steps judge what a role may change. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
