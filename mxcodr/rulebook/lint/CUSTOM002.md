---
step: catalog
level: off
check: mxcli
key: document
---

# CUSTOM002 — microflows should have standard naming prefixes (ACT_, SUB_, DS_, VAL_, SCH_)

## What it checks
mxcli lint rule CUSTOM002 (Microflow Prefix Convention): Microflows should have standard naming prefixes (ACT_, SUB_, DS_, VAL_, SCH_). Off: Microflow prefixes: the naming step and its skill say which flows take a prefix; candidate for warn. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
