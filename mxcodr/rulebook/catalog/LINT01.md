---
step: catalog
level: off
check: mxcli
key: none
---

# LINT01 — an mxcli lint rule that has no card yet

## What it checks
Every mxcli lint rule has its own card in lint/, with its level. This card is for a rule a newer mxcli brought that has no card yet: off, so a new rule never changes the gate unnoticed. Set level: warn below to see such findings under the warnings, block to make their errors block.

## Fix
Give the rule its own card in lint/ (what mx-codr does when it moves to that mxcli).

## Local
# level: off

