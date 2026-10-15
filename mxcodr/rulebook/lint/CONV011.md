---
step: catalog
level: warn
check: mxcli
key: document
---

# CONV011 — commits should not be inside loops, whether a commit action or a create/change with commit (N+1 performance issue)

## What it checks
mxcli lint rule CONV011 (NoCommitInLoop): Commits should not be inside loops, whether a commit action or a create/change with commit (N+1 performance issue). A commit inside a loop is one database round trip per row (N+1); commit the list once after the loop. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: warn
# except: Module.Document  # why
