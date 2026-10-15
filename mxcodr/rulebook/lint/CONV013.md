---
step: catalog
level: warn
check: mxcli
key: document
---

# CONV013 — external service calls (REST, web service, Java action) should have custom error handling

## What it checks
mxcli lint rule CONV013 (ErrorHandlingOnCalls): External service calls (REST, web service, Java action) should have custom error handling. A REST, web service or Java action call without custom error handling ends the user's action with a system error. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: warn
# except: Module.Document  # why
