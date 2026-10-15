---
step: catalog
level: off
check: mxcli
key: document
---

# CONV018 — modules past a readable size should organise their documents into folders

## What it checks
mxcli lint rule CONV018 (ModuleFolderOrganization): Modules past a readable size should organise their documents into folders. Off: FOLDER01 already checks this in the gate. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
