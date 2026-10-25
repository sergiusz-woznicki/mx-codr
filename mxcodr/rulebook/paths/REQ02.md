---
step: paths
level: block
check: requirement_rules.cjs#requirementFindings
key: document
---

# REQ02 — each agreed requirement has a test

## What it checks
Each requirement in docs/brain/plan is named by a test, and the code under its `# requirement:` line holds one of the requirement's own words, so none drops out or is named without a check. A data rule no screen shows (a format, uniqueness, a bound) may be named by a microflow test (`-- requirement:` in tests/<feature>.test.mdl, while MFTEST01 blocks); a requirement whose "checked when" names a screen, a button or what a person sees needs a browser test. A quoted format with placeholders (`LN/YYYY/0001`) is looked for by its pattern or an instance. Lines that read the model back (`describe`, `show`, a catalog query, or a variable holding one) do not count. At `requirements: assume` nothing may wait in the brain's queue, since nobody else promotes it.

## Fix
`# requirement: <id>` above the step that checks it; its fail message in the requirement's words. Reading the model back (`describe`, `show`, a catalog query) is not a check of what the app does.

## Local
# level: block
# except: <id>   # why
