---
step: naming
level: warn
check: naming_rules.cjs#decisionFindings
key: none
baseline: captions
---

# CAPTION05 — a decision's caption is a question in words, not the expression

## What it checks
A decision's caption is not the expression itself ($Order/Total > 1000). It says the question in words.

## Fix
As CAPTION01: warns until the first DONE, then blocks a microflow new or changed since.

## Local
# level: warn

