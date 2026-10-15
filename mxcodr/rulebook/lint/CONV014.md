---
step: catalog
level: warn
check: mxcli
key: document
---

# CONV014 — activities should not use 'Continue' error handling which silently swallows errors

## What it checks
mxcli lint rule CONV014 (NoContinueErrorHandling): Activities should not use 'Continue' error handling which silently swallows errors. Continue error handling swallows the error: the flow goes on as if it worked. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: warn
# except: Module.Document  # why
