---
step: catalog
level: off
check: mxcli
key: document
---

# CONV012 — exclusive splits should have a meaningful caption describing the decision

## What it checks
mxcli lint rule CONV012 (ExclusiveSplitCaption): Exclusive splits should have a meaningful caption describing the decision. Off: the naming step (decision captions) already checks this in the gate. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
