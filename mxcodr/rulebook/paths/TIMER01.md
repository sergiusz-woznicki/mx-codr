---
step: paths
level: block
check: check_paths.cjs#findings
key: document
baseline: paths
---

# TIMER01 — the work of a timer or a scheduled event runs in a test

## What it checks
Every scheduled event of the app's own modules runs a microflow that a test runs, and every workflow timer (a boundary event on a user task) calls a microflow that a test runs. A test cannot wait three days or for the night, so what happens then is otherwise never seen: an escalation, a reminder, a clean-up. A microflow test (`tests/<feature>.test.mdl`) that calls it counts, and so does a browser test that starts it by hand and names it on its `# covers:` line.

## Fix
Put the timer's work in a microflow it calls (`call microflow Module.SUB_Escalate(Request = $WorkflowContext)` in the boundary event); call it in a microflow test on a record past the deadline and assert what changed.

## Local
# level: block
# except: Module.Document   # why
