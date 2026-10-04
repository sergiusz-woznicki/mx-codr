# coverage, precheck, the suite and the runtime

One line per code the `mx`, `coverage`, `security`, `scope`, `tests`, `visual` and the precheck step can print. Every code blocks DONE unless its line
says "warning". The finding already says what to change; this says why. Not `tests/gate/*.sh`.

| Code | Wants | Fix |
|---|---|---|
| `coverage` | every page and `ACT_` microflow named on a `# covers:` line of some `tests/verify-*.test.sh` | names separated by commas or spaces; a `SUB_`, an entity or an enumeration does not count |
| `SCRIPT01` | each document created in one script only | change it there or with `alter`, never a second `create or modify` in a later script |
| `security` | `PRODUCTION` once users sign in | `alter project security level PRODUCTION;` in the first script (`MDL_REQUIRE_PRODUCTION=0` only for an app with no users) |
| stale client bundle | a test failed on a 404 for `dist/*.js` after a `--watch` rebuild (the failure line says so) | `bash tests/gate.sh --restart --only <feature>` -- not the page, not a widget |
| `VIEW01` | a view a role reads with no XPath while it sees only its own rows of its data | constrain the rule, or revoke it and read the view in a data-source microflow |
| `SCOPE01` | a page's data source microflow ties its retrieve to the user when the page's role reads that entity through an XPath-scoped rule (warning) | microflows ignore entity access: constrain its retrieve (`... = '[%CurrentUser%]'` or `= $SignedInCustomer`); `MDL_SCOPE=error` blocks |
| `RUNTIME01` | no `ERROR` in the server log while the suite ran (warning) | the log line names the microflow or page; `MDL_RUNTIME_ERRORS=error` makes it block |
| `VIS01` `VIS02` `VIS03` `VIS04` | no overlapping widgets, sideways scroll, cut-off text, or chart bigger than the screen, on the page a test ends on (warning) | usually a box class on inline text or a negative margin; a chart needs a height that fits; `MDL_VISUAL=error` makes them block |
| `LOOK01` `LOOK02` | screenshots reviewed with `MDL_VISUAL_REVIEW=agent` (warning) | read each PNG in `.mxcli/visual/review.md`, write `verdicts.json` |
| "went green without ever being red" | a test that was seen to fail once (warning) | break the feature, `bash tests/gate.sh --only <feature>`, fix it; or list the test in `MDL_ALLOW_GREEN_FIRST` when green by nature |
| `CE0582` | no classic drop-down (not React-client compatible) | `combobox` or `radiobuttons` on the same enumeration or Boolean attribute |
| `CE0106` `CE0557` | a microflow or page reached from a page, button or menu has a role | the hint gives `grant execute on microflow <name> to <role>;` / `grant view on page <name> to <role>;` -- put it in the script that creates the document |
| `CE0007` `CE0117` `CE0161` `CE0642` `CE1613` `CE2729` `CE7247` | build errors the gate and precheck print a hint for | read the hint under the error; the pitfalls in the syntax digest cover the same ground |
| `CE7247` | a reserved name, or an invalid URL (a REST client BaseUrl set to a constant) -- the hint follows the message | rename Owner/Type/Default; a BaseUrl is a literal http(s):// address, a mock URL is built in the microflow |
| missing Marketplace module | mx check: "couldn't find the X module in your app" -- not logged in, so every build and gate waits (MDL_MARKETPLACE_LOGIN=wait) | ask the person to run `./mxcli auth login` once in their terminal; then `./mxcli marketplace search` and `install <id>`; never build a replacement. Skip the module: `MDL_MARKETPLACE_LOGIN=report` |
