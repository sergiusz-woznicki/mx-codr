---
step: layout
level: block
check: layout_rules/spacing.cjs#check
key: none
---

# SPACE02 — Atlas spacing only (None, S, M, L)

## What it checks
Spacing uses only the Atlas sizes None, S, M or L. Other values make the Mendix build fail.

## Fix
Atlas `margin-`/`padding-` sides, `None S M L`; no `Class:`.

## Local
# level: block

