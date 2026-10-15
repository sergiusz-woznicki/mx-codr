---
step: catalog
level: off
check: mxcli
key: document
---

# QUAL006 — checks that every caption mxbuild requires (a tab page caption) has text in the project's default language (CE4899)

## What it checks
mxcli lint rule QUAL006 (RequiredCaptionMissingDefaultLanguage): Checks that every caption mxbuild requires (a tab page caption) has text in the project's default language (CE4899). Off: a build error, so mx check in the gate already blocks it. Decided 2026-10-15 in the review of every mxcli lint rule.

## Fix
In the finding: mxcli's message and its suggestion.

## Local
# level: off
# except: Module.Document  # why
