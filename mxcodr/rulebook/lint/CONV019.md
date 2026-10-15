---
step: catalog
level: off
check: mxcli
key: document
---

# CONV019 — pages reachable from navigation should have a URL so they can be linked to directly

## What it checks
mxcli lint rule CONV019 (NavigationPageURL): Pages reachable from navigation should have a URL so they can be linked to directly. Off: URL01 already checks this in the gate. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
