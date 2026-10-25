---
step: paths
level: warn
check: check_paths.cjs#findings
key: document
baseline: paths
---

# TIMER01 — the work of a timer or a scheduled event, suggested for a microflow test

## What it checks
Every scheduled event of the app's own modules runs a microflow, and every workflow timer (a boundary event on a user task) calls one, that some test runs. A test cannot wait three days or for the night, so what happens then (an escalation, a reminder, a clean-up) is otherwise never seen. A warning, never an obligation: it is listed as a suggested microflow test for the final report. A browser test that clicks an action the request asked for and names it on its `# covers:` line counts; never build an action only to test it.

## Fix
Nothing now: copy the line into your final report under "Suggested microflow tests". A timer whose work is in no microflow: put it in one the timer calls (`call microflow Module.SUB_Escalate(Request = $WorkflowContext)` in the boundary event).

## Local
# level: warn
# except: Module.Document   # why
