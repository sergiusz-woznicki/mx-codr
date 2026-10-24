---
step: catalog
level: warn
check: mxcli
key: document
---

# CONV020 — A microflow creates an object of a persistent entity without committing it, and never commits, returns, passes on, stores or deletes it

## What it checks
mxcli lint rule CONV020 (CreatedObjectNeverPersisted, mxcli 0.28): A microflow creates an object of a persistent entity without committing it, and never commits, returns, passes on, stores or deletes it. Such an object is silently lost when the microflow ends; mx check and the gate's other steps do not see it, so a data-loss bug stays invisible until a test reads the row. Decided 2026-10-25 when mxcli 0.28 brought the rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: warn
# except: Module.Document  # why
