---
step: paths
level: block
check: requirement_rules.cjs#requirementFindings
key: document
---

# REQ02 — each agreed requirement has a test

## What it checks
Each requirement in docs/brain/plan is named by a test, and the code under its `# requirement:` line holds one of the requirement's own words, so none drops out or is named without a check. Lines that read the model back (`describe`, `show`, a catalog query, or a variable holding one) do not count. At `requirements: assume` nothing may wait in the brain's queue, since nobody else promotes it.

## Fix
`# requirement: <id>` above the step that checks it; its fail message in the requirement's words. Reading the model back (`describe`, `show`, a catalog query) is not a check of what the app does.

## Local
# level: block
# except: <id>   # why
