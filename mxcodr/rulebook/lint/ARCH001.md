---
step: catalog
level: off
check: mxcli
key: document
---

# ARCH001 — pages and widgets should only use data from entities in the same module

## What it checks
mxcli lint rule ARCH001 (Cross-Module Data Access): Pages and widgets should only use data from entities in the same module. Off: Pages across modules are allowed where the module structure says so. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
