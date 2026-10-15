---
step: catalog
level: off
check: mxcli
key: document
---

# CONV006 — entity access rules should not grant CREATE or DELETE directly; use microflows instead

## What it checks
mxcli lint rule CONV006 (NoCreateDeleteRights): Entity access rules should not grant CREATE or DELETE directly; use microflows instead. Off: Employees create and delete through the app's own pages; the security step judges access. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
