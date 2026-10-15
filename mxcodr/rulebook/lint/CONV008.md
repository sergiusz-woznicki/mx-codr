---
step: catalog
level: off
check: mxcli
key: document
---

# CONV008 — each module role should be mapped to exactly one user role

## What it checks
mxcli lint rule CONV008 (ModuleRoleMapping): Each module role should be mapped to exactly one user role. Off: A Manager role includes the Employee module role: one module role in several user roles is intended. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
