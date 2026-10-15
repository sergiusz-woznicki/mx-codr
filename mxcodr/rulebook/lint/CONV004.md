---
step: catalog
level: off
check: mxcli
key: document
---

# CONV004 — enumeration names should start with ENUM_ prefix

## What it checks
mxcli lint rule CONV004 (EnumerationPrefix): Enumeration names should start with ENUM_ prefix. Off: Enumerations are named for what they hold, without an ENUM_ prefix. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
