---
step: catalog
level: off
check: mxcli
key: document
---

# ARCH003 — persistent entities should have a unique, not-null attribute as a business key

## What it checks
mxcli lint rule ARCH003 (Entity Business Key): Persistent entities should have a unique, not-null attribute as a business key. Off: Most findings are on Marketplace modules' entities; a business key where one is needed is a requirement, not a lint rule. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
