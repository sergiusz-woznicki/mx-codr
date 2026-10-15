---
step: catalog
level: off
check: mxcli
key: document
---

# CONV007 — entity READ/WRITE access rules should have XPath constraints for row-level security

## What it checks
mxcli lint rule CONV007 (XPathOnAllAccess): Entity READ/WRITE access rules should have XPath constraints for row-level security. Off: Some roles read every row on purpose (an employee sees all orders); FILTER01 judges the rows a page promises. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
