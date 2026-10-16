---
step: precheck
level: block
check: gate_scripts.cjs#unanchoredFeaturesCommand
key: none
---

# REQ03 — a later request records its requirements

## What it checks
Once the app has pages and docs/brain/plan/ has requirements, a new page or ACT_ microflow waits until a requirement names it (`-a @Module.Doc`), recorded or staged. So every request leaves its requirements in the plan, the built ones and the ones not built yet, and the next session's orient.sh lists what is still open. MDL_REQUIREMENTS=off in tests/harness.env turns it off with the interview.

## Fix
`brain capture -a @<Doc>` per statement, unbuilt ones too.

## Local
# level: block
