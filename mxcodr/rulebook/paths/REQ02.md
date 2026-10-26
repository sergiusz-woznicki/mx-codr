---
step: paths
level: block
check: requirement_rules.cjs#requirementFindings
key: document
---

# REQ02 — each agreed requirement has a test

## What it checks
Each requirement in docs/brain/plan is named by a test, and the code under its `# requirement:` line holds one of the requirement's own words, so none drops out or is named without a check. Only a browser test proves one; a microflow test never does. A requirement whose "checked when" names no screen, button or thing a person sees (a format, uniqueness, a bound no requested screen reaches) and that no test names is a warning, a suggested microflow test for the final report: never build a page only to test it. A quoted format with placeholders (`LN/YYYY/0001`) is looked for by its pattern or an instance. Lines that read the model back (`describe`, `show`, a catalog query, or a variable holding one) do not count. At `requirements: assume` nothing may wait in the brain's queue, since nobody else promotes it.

## Fix
`# requirement: <id>` above the step that checks it; its fail message in the requirement's words. Reading the model back (`describe`, `show`, a catalog query) is not a check of what the app does.

## Local
# level: block
# except: <id>   # why
