---
step: catalog
level: off
check: mxcli
key: document
---

# CONV005 — snippet names should start with SNIPPET_ prefix

## What it checks
mxcli lint rule CONV005 (SnippetPrefix): Snippet names should start with SNIPPET_ prefix. Off: Snippets follow the harness's names (SNIPPET_CurrentUser is the one convention it asks for). Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
