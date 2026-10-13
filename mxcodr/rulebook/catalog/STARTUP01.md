---
step: catalog
level: block
check: catalog_rules.cjs#startupReturnsFalse
key: document
---

# STARTUP01 — the after-startup microflow returns true on every path

## What it checks
The microflow the app runs at startup (Settings, After startup) never returns false. Mendix stops the app when it does, so a seed that returns false once its rows exist lets the app start once, on an empty database, and fails every restart after -- while the running app passes every test.

## Fix
In the flow, `else return true;` where its work was already done; return false only for a real failure. `alter microflow` the flow, or change its script and exec it again.

## Local
# level: block
# except: Module.Microflow   # why
