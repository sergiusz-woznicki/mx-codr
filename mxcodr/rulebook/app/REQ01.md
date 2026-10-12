---
step: precheck
level: block
check: gate_scripts.cjs#newFeaturesCommand
key: none
---

# REQ01 — requirements recorded before building

## What it checks
Before the first pages and ACT_ microflows of an app (it has no page of its own yet), docs/brain/plan/ holds the requirements, recorded or waiting for the person's yes; until then the exec is refused, with the procedure in the message. An app that grew without a brain gets a warning after the exec instead. MDL_REQUIREMENTS=off in tests/harness.env turns it off with the interview.

## Fix
A `brain capture` per testable statement; open ones `Assumed:` --open.

## Local
# level: block
