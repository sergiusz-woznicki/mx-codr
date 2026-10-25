---
step: tests
level: warn
check: bash:tests/gate/mftest.sh#run_microflow_tests
key: none
---

# MFTEST01 — the optional microflow tests pass

## What it checks
Microflow tests are never an obligation. When tests/ holds some (`*.test.mdl`, `*.test.md`), a full gate with the rest green runs them on a copy of the project, with its own runtime and scratch database, so the app and its data are not touched. Red, or unable to run, is a warning that never holds DONE; the result is replayed until the model or a test file changes.

## Fix
Optional: read the test first; fix it or the flow, or delete it (.mxcli/microflow-tests.txt).

## Local
# level: warn
