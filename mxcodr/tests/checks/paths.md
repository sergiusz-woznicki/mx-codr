# paths -- every path a user can take has a test (`check_paths.cjs`)

One line per code of the `paths` step; every code blocks DONE unless marked warning. The card: `tests/rulebook/paths/<CODE>.md`.

| Code | Wants | Fix |
|---|---|---|
| `ISO01` | each row-scoped role reads its entity in a test | As that user, show one of its own rows is there and another user's row is not (`oql_count` with the other user's key = 0, or the API the role reads through). |
| `OUTCOME01` | every message a user can be shown is asserted by a test | Walk the path that shows it and assert four words of it in a row, or all of a shorter one: `await_message(/credit limit exceeded for/i)`; the refusals too, not only the successes. |
| `REQ02` | each agreed requirement has a test | `# requirement: <id>` above the step that checks it; its fail message in the requirement's words. Reading the model back (`describe`, `show`, a catalog query) is not a check of what the app does. |
| `REQ04` | the requirements keep what the request spells out | `./mxcli brain capture "<requirement>" --slice <slice>` with the detail in it and a "checked when" that asserts it, then promote it (a capture that repeats the request passes the scope freeze). Built differently: `Assumed: ...` --open, naming the detail and the platform error that stopped you; a rule code that seems to refuse it: read its card and build the form it allows. |
| `ROLE01` | every demo user's role is the user of some test | A journey per role: what it sees, and what it is refused. |
| `SCOPE02` | a new page or ACT_ microflow serves an approved requirement | Name it on the `# covers:` line of the test file that holds its requirement, or take it out of the script and list the idea under "to add next" in the report. At requirements: assume the scope is frozen once the requirements are promoted: do not capture a new one for it. |
| `SCOPE03` | warning: nothing in the app is outside the approved requirements | Tie it to the approved requirement it serves (the test that checks that requirement names it on its `# covers:` line), or leave it out and list the idea under "to add next" in the final report. |
| `SVC01` | every published service is called by a test | Each operation as a user who may, the answer asserted, and once without signing in (refused). |
| `TIMER01` | warning: the work of a timer or a scheduled event, suggested for a microflow test | Nothing now: copy the line into your final report under "Suggested microflow tests". A timer whose work is in no microflow: put it in one the timer calls (`call microflow Module.SUB_Escalate(Request = $WorkflowContext)` in the boundary event). |
| `WF01` | a flow that completes a workflow task checks the user is one of its targets | Retrieve the task's `System.WorkflowUserTask_TargetUsers`, refuse when `[%CurrentUser%]` is not in it; grant the flow only to the roles the task targets. |
| `WF02` | every workflow task outcome is chosen in a test that signs in as both people | Start the flow as one demo user, `sign_in_as('<the targeted user>')`, choose the outcome, sign back in as the first and assert what they see; one test per outcome. |
