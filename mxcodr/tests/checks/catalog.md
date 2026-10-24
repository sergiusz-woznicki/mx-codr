# catalog -- rules the model catalog answers (`catalog_rules.cjs`); mxcli lint on request

One line per code of the `catalog` step; every code blocks DONE unless marked warning. The card: `tests/rulebook/catalog/<CODE>.md`.

| Code | Wants | Fix |
|---|---|---|
| `ASKED01` | a calendar, map or chart the request names is on a page | `./mxcli marketplace search "calendar"`, install the widget, put it on the page with the data the person named; when it cannot be installed, say so in the final report. |
| `LINT01` | off unless the rulebook turns it on: an mxcli lint rule that has no card yet | Give the rule its own card in lint/ (what mx-codr does when it moves to that mxcli). |
| `PUBLISH01` | a business event the app publishes is really published | mxcli (0.26 - 0.28) cannot write `BusinessEvents.PublishBusinessEvent_V2` (CE0115): a Java action of your own that publishes (pitfalls); test that it ran. |
| `SEC007` | anonymous users cannot read every row of an entity (DIVD-2022-00019) | An XPath constraint on the anonymous role's read rule, or revoke the grant if the data is not public. |
| `SEED01` | warning: a role that only reads a list finds rows in it | Create a few realistic rows in the after-startup microflow, only when none exist yet, linked to the demo users who should see them, and return true on every path; no after-startup microflow yet: `alter settings runtime ( AfterStartupMicroflow: 'Module.ASU_Seed' )`. An app that really starts empty: say so in the final report. |
| `STARTUP01` | the after-startup microflow returns true on every path | In the flow, `else return true;` where its work was already done; return false only for a real failure. `alter microflow` the flow, or change its script and exec it again. |
| `STATUS01` | warning: a button that sets one status is gone once the object has it | `alter page Mod.Invoice_Detail { set Visible = [Status != Mod.InvoiceStatus.Sent] on InvoiceDetail_SendButton };` and the same `Visible:` in the script that creates the page; the flow checks the status too. |
| `UI001` | a data grid filters itself, not through a hand-built filter bar | One filter in the column (`textfilter`, `numberfilter`, `datefilter`, `dropdownfilter`, for an association `(Association: ..., datasource: database ..., CaptionAttribute: ...)`); never a filter bar over a helper entity. |

mxcli lint rules this app reports (cards in `tests/rulebook/lint/`; the finding carries mxcli's own fix): `CONV010` (warning), `CONV011` (warning), `CONV013` (warning), `CONV014` (warning), `CONV020` (warning), `MPR002` (warning), `MPR006` (warning), `MPR013` (warning), `SEC006` (warning), `SEC008` (warning), `SEC009` (warning), `SEC010` (warning).
