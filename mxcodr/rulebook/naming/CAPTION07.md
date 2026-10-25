---
step: naming
level: block
check: naming_rules.cjs#loopFindings
key: none
---

# CAPTION07 — no @caption on a loop: mxcli drops it, the annotation carries the text

## What it checks
A loop has no caption: mxcli drops loop captions, so the text belongs in the annotation.

## Fix
As CAPTION01: warns until the first DONE, then blocks a microflow new or changed since.

## Local
# level: block

