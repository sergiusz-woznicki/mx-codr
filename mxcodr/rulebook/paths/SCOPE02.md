---
step: paths
level: block
check: gate_scripts.cjs#unplannedScopeCommand
key: none
---

# SCOPE02 — a new page or ACT_ microflow serves an approved requirement

## What it checks
During the first build, a page or ACT_ microflow these scripts create must serve one of the approved requirements: a requirement anchors it (`-a @Module.Doc`), or a test that names a requirement (`# requirement: <id>`) covers it. Otherwise the exec is refused before it touches the model. The home and login pages, seed flows and everything with no requirement of its own (snippets, DS_ and SUB_ flows, entities) are never flagged. Nothing is checked while no requirement is recorded, after the app's first DONE (REQ03 asks every later page for an anchor) or with MDL_REQUIREMENTS=off in tests/harness.env.

## Fix
Name it on the `# covers:` line of the test file that holds its requirement, or take it out of the script and list the idea under "to add next" in the report. At requirements: assume the scope is frozen once the requirements are promoted: do not capture a new one for it.

## Local
# level: block
