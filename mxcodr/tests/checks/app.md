# app -- mx check, coverage, precheck, scope, unused, the suite, visual and runtime

One line per code of the `mx`, `coverage`, `precheck`, `scope`, `unused`, `tests` steps; every code blocks DONE unless marked warning. The card: `tests/rulebook/app/<CODE>.md`.

| Code | Wants | Fix |
|---|---|---|
| `COVERAGE01` | every page and ACT_ microflow is on a test's # covers: line | Names separated by commas or spaces; a `SUB_`, an entity or an enumeration does not count. |
| `LOOK01` | warning: every screenshot the suite took has been reviewed (MDL_VISUAL_REVIEW=agent) | Read each PNG in `.mxcli/visual/review.md`; write `verdicts.json`. |
| `LOOK02` | warning: no reviewed screenshot was rejected (MDL_VISUAL_REVIEW=agent) | Read each PNG in `.mxcli/visual/review.md`; write `verdicts.json`. |
| `MX01` | Mendix's consistency check reports 0 errors | The CE hints under each error; the pitfalls in the syntax digest cover the same ground. |
| `REQ01` | requirements recorded before building | A `brain capture` per testable statement; open ones `Assumed:` --open. |
| `RUNTIME01` | warning: no server error logged while the suite ran | The log line names the flow or page; `level: block` in ## Local blocks. |
| `SCOPE01` | warning: a data source microflow scopes its rows to the user, as the role does | Constrain its retrieve to the user: microflows skip entity access. |
| `SCRIPT01` | each document is created by one script in mdlsource/ | Change it there or with `alter`, never a second `create or modify` in a later script. |
| `STALE01` | a re-run script does not undo later changes to its documents | A new `alter` script, or DESCRIBE those documents into it first. |
| `TEST01` | a test exists before a new page or ACT_ microflow | Write `tests/verify-<feature>.test.sh` first, run it (red), then exec; a fix to an existing page passes. |
| `TESTS01` | every browser test passes | Read the failing scenario's own message; the test names the widget and the page. |
| `UNUSED01` | nothing is left that nothing uses | The `drop` lines given, plus its `mdlsource/` source and `# covers:` name; to keep one: `except:` in ## Local. |
| `VIS01` | warning: no two widgets overlap on the page a test ends on | Usually a box class on inline text or a negative margin (`level: block` in ## Local blocks). |
| `VIS02` | warning: the page does not scroll sideways | A negative margin or a fixed width wider than the screen (`level: block` in ## Local blocks). |
| `VIS03` | warning: no text is cut off by its box | A fixed height or a box class on inline text; on a phone, PHONE03. |
| `VIS04` | warning: a chart fits one screen | A chart height that fits one screen (`level: block` in ## Local blocks). |
| `VIS05` | warning: a phone's bar stays on screen | See PHONE04. |
| `VIS06` | warning: phone: title row on top | See PHONE06. |
| `VIS07` | amounts look alike | `formatDecimal($V, '#,##0.00')` |
| `WAIT01` | warning: a test waits for events, not for time | Await what the action causes (`await_message`, `landed`, a locator); a filtered list: `filter_list`. |

## Hints: what the gate says when...

| Situation | Wants | Fix |
|---|---|---|
| stale client bundle | a test failed on a 404 for `dist/*.js` after a `--watch` rebuild | `bash tests/gate.sh --restart --only <feature>` -- not the page, not a widget |
| Studio Pro has this project open | its next save replaces what mxcli wrote (warning) | close Studio Pro without saving, or make the change there |
| "went green without ever being red" | a test seen to fail once (warning) | break the feature, run `--only <feature>`, fix it; or `MDL_ALLOW_GREEN_FIRST` when green by nature |
| `CE0582` | no classic drop-down (not React-client compatible) | `combobox` or `radiobuttons` on the same enumeration or Boolean attribute |
| `CE0106` `CE0557` | a microflow or page reached from a page, button or menu has a role | the hint's `grant execute` / `grant view` in the script that creates the document |
| `CE0007` `CE0117` `CE0161` `CE0642` `CE1613` `CE2729` `CE7247` | build errors the gate and precheck explain | read the hint under the error |
| `CE7247` | a reserved name, or an invalid URL (a REST client BaseUrl set to a constant) | rename Owner/Type/Default; a BaseUrl is a literal http(s):// address, a mock URL is built in the microflow |
| missing Marketplace module | mx check: "couldn't find the X module" (not logged in) | ask the person for `./mxcli auth login`, then `marketplace install <id>`; never build a replacement |
