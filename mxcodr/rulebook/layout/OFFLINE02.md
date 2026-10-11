---
step: layout
level: block
check: layout_rules/offline.cjs#offlineFindings
key: none
---

# OFFLINE02 — an offline profile syncs entities

## What it checks
An offline profile downloads nothing until each entity has a sync mode, and then shows an empty app while every check passes. At least one entity is synchronized with all or where.

## Fix
`sync Module.Entity all;` in its sync block.

## Local
# level: block
