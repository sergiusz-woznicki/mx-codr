---
step: catalog
level: off
check: mxcli
key: document
---

# QUAL004 — elements should be referenced somewhere in the project or marked as entry points

## What it checks
mxcli lint rule QUAL004 (Orphaned Elements): Elements should be referenced somewhere in the project or marked as entry points. Off: UNUSED01 already checks this in the gate. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
