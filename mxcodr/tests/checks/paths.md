# paths: every testable path has a test

The `paths` step reads the paths from the model, whatever the app does, and asks for a test of each.
A test walks a path when it asserts what the user meets there; a `# covers:` line, a comment or a
`.test.mdl` file (the gate does not run those) walks nothing. Paths that were in the model when the harness was installed and have not changed are
warnings, the backlog; a new or changed one blocks DONE (`MDL_PATHS=error` in `tests/harness.env`:
the backlog blocks too). Every finding, old ones included: `.mxcli/paths.txt` after each gate.

| Code | Wants | Fix |
|---|---|---|
| `OUTCOME01` | every message a user can be shown -- `show message`, `validation feedback`, an attribute's `error message`, text handed to a flow that shows or stores it for a page -- asserted by a test | walk the path that shows it and assert four words of it in a row, or all of a shorter one: `await_message(/credit limit exceeded for/i)`; the refusals too, not only the successes |
| `WF01` | a flow that completes a workflow user task checks the signed-in user is one of the task's targets (blocks, old or new) | retrieve the task's `System.WorkflowUserTask_TargetUsers`, refuse when `[%CurrentUser%]` is not in it; grant the flow only to the roles the task targets |
| `WF02` | each user task: every outcome chosen in a test, and a test of it that signs in as two users | start the flow as one demo user, `sign_in_as('<the targeted user>')`, choose the outcome, sign back in as the first and assert what they see; one test per outcome |
| `ISO01` | each role that reads an entity through an XPath (its own rows): a test signed in as a user with that role reads that entity | as that user, show one of its own rows is there and another user's row is not (`oql_count` with the other user's key = 0, or the API the role reads through) |
| `ROLE01` | every demo user's role is the user of some test | a journey per role: what it sees, and what it is refused |
| `SVC01` | every published REST and OData service called by a test | each operation as a user who may, the answer asserted, and once without signing in (refused) |

What the gate cannot see: a decision whose branch shows nothing to the user. Give such a branch a
test anyway (assert its effect in the database), and say so in the test's header.
`MDL_UNTESTED=Key,...` in `tests/harness.env` (the person's, the guard refuses a session that sets
it) lists paths deliberately left without a test: the key is the document, `Module.Workflow/Task`,
`Module.Entity|Module.Role`, `role:<UserRole>` or the service.
