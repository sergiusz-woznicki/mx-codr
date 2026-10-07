# Every testable path

Before the first test of a feature, list its paths. A path is one way a user can go through it and
what they meet at the end. The gate's `paths` step finds most of them in the model and blocks DONE
until a test walks each; the list below is how to find them first, so the tests come before the code.

## Where the paths are

| In the model | The paths | What the test asserts |
|---|---|---|
| a decision in a microflow or nanoflow | each branch | what the user meets on it -- a message, a page, a saved value |
| a message (`show message`, `validation feedback`, an attribute's `error message`, a notice the app stores for a page) | the branch that shows it | four words of it in a row, after the action that causes it |
| a rule that refuses (a limit, a status order, a required field, an owner check) | the allowed case AND the refused one | the refusal message, and that nothing changed in the database |
| a workflow user task | each outcome | the outcome chosen by the user the task targets, then what the starter sees |
| a role | its journey | what it sees, and that a page or action of another role is refused |
| an access rule with an XPath (own rows only) | own row visible, another user's row not | as that user, in the browser or through its API; `oql_*` reads as administrator and proves nothing about a role |
| a published REST or OData service | each operation, and no sign-in | the answer for a user who may; refused without credentials |
| a scheduled event | its microflow | run it by hand from a test-only action, assert its effect |

## A journey of several people

```bash
#!/usr/bin/env bash
# covers: Shop.ACT_Order_Submit, Shop.Approval_Task, Shop.ACT_Approval_Approve
# A large order needs a manager: the employee submits it and cannot confirm it yet, the manager
# approves it from their task list, and the employee can then confirm it.
export TEST_USER=demo_employee
. "$(dirname "$0")/lib.sh"
result="$(scenario '
  await open_app();
  // ... create the order, then:
  await page.click(".mx-name-OrderDetail_SubmitButton");
  await await_message(/sent for manager approval/i);
  await sign_in_as("demo_manager");
  await menu("My approvals", "MyApprovals_TaskGrid");
  await row_action("MyApprovals_TaskGrid", vars.NO, "MyApprovals_OpenButton");
  await page.click(".mx-name-ApprovalTask_ApproveButton");
  await await_message(/order .* approved/i);
  await sign_in_as("demo_employee");
  // ... open the order: Confirm is enabled now
')"
```

One test per outcome (approve, reject), and one where a user the task does not target opens it and
is refused. A flow that completes a task checks the user is a target first (WF01).

## What the gate cannot see

A branch that shows nothing (it only saves or skips) has no message to look for. Test it anyway --
assert its effect in the database -- and say in the test's header which branch it walks.
