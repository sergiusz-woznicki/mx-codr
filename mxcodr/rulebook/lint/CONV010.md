---
step: catalog
level: warn
check: mxcli
key: document
---

# CONV010 — ACT_ microflows should only contain UI actions and sub-microflow calls

## What it checks
mxcli lint rule CONV010 (ACTMicroflowContent): ACT_ microflows should only contain UI actions and sub-microflow calls. An ACT_ microflow is what a button calls; Mendix keeps it to UI actions and SUB_ calls so the business step can be reused and tested. A warning: older apps have many. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: warn
# except: Module.Document  # why
