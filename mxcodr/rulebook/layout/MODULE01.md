---
step: layout
level: block
check: layout_rules/accounts.cjs#templateModuleFindings
key: none
---

# MODULE01 — MyFirstModule gone once the app has a module

## What it checks
The empty MyFirstModule from the Mendix template is deleted once the app has its own module. The finding lists what still uses it.

## Fix
`drop module MyFirstModule;` once nothing points at it.

## Local
# level: block

