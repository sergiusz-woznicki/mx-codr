---
step: catalog
level: off
check: mxcli
key: document
---

# CUSTOM001 — entity names must use PascalCase naming convention

## What it checks
mxcli lint rule CUSTOM001 (Entity PascalCase): Entity names must use PascalCase naming convention. Off: NAME01 and NAME02, and the naming step already checks this in the gate. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
