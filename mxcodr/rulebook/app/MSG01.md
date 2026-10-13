---
step: precheck
level: block
check: gate_scripts.cjs#lowerCaseMessageTypes
key: none
---

# MSG01 — a message type is written with a capital

## What it checks
`show message ... type Warning` (Information, Error), never `type warning`. In lower case mxcli stores the word as written, and the next tool that saves the model (`mxcli fix widgets`, which runs after an exec that writes a data grid, or Studio Pro) turns it into Information: the person sees a warning as plain information, and the script no longer matches the model.

## Fix
In the finding.

## Local
# level: block
