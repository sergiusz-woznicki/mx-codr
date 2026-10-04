# What each check code wants, and its fix

One line per code the gate, the precheck or a hook can print. Read this, not `tests/gate/*.sh`
or the checkers: the finding already says what to change, and this page says why. Every code
here blocks DONE unless the line says "warning".

## layout -- the shape of a signed-in app (`tests/gate.sh`, skill `spacing-and-layout`)

| Code | Wants | Fix |
|---|---|---|
| `NAV01` | a way to log out once users sign in | `menu item 'Log out' sign_out icon Atlas_Core.Atlas_Filled.logout;` as the menu's last item |
| `NAV02` | Log out last in the menu | move it to the end |
| `NAV03` | every role's home page in the menu | `menu item '<caption>' page <Page> icon <icon>;` before Log out |
| `NAV04` | no hand-built menu of link buttons in a layout | put those pages in the navigation profile's menu; the layout keeps Atlas's own menu |
| `NAV05` | an icon on every menu entry | `icon Atlas_Core.Atlas_Filled.<name>` at the end of the item |
| `NAV06` | no icon twice in what one role sees | the other icon the message suggests |
| `HOME01` | administrators open on a page of the app's own module | create `<Module>.Admin_Home` and `home page <Module>.Admin_Home for Administrator` |
| `ACCOUNT01` | a Users item for administrators | `menu item 'Users' page Administration.Account_Overview icon Atlas_Core.Atlas_Filled."user-neutral-shield";` before Log out |
| `ACCOUNT02` | a My account item | `menu item 'My account' microflow Administration.ManageMyAccount icon Atlas_Core.Atlas_Filled.user;` before Log out |
| `ACCOUNT03` | every signing-in role can open My account; someone can manage users | `alter user role <Role> add module roles (Administration.User);` and `Administration.Administrator` on the administrators' role |
| `MODULE01` | `MyFirstModule` gone once the app has its own module | re-point home pages, drop `MyFirstModule.User` from user roles, `drop module MyFirstModule;` |
| `USER01` | who is signed in, top right, on every page | the page starts with `container ctPageTop (DesignProperties: ['Flex container': 'Horizontal (row)', 'Align items X': 'Right'])` holding `snippetcall scCurrentUser (Snippet: <Module>.SNIPPET_CurrentUser)`; with a Back button, `'Space between (only for horizontal containers)'` |
| `BACK01` | Back, top left, on every page another page or microflow opens | first widget `actionbutton btnBack (Caption: 'Back', Action: CLOSE_PAGE, Icon: 'Atlas_Core.Atlas_Filled.chevron-left')`; pop-ups excepted |
| `ICON01` | an icon on every button | `Icon: 'Atlas_Core.Atlas_Filled.floppy-disk'` Save, `trash-can` Delete, `pencil` Edit, `add` New, `view` Open |
| `LAYOUT01` | one layout for every page that is not a pop-up | pick one (`Atlas_Core.Atlas_Default`) and set it on every page |
| `EDGE01` | widgets inside a layout grid | `layoutgrid pageGrid { row rowTop { column colTop (DesktopWidth: 12) { ... } } }` around the page's widgets, the top row too |
| `SPACE01` | a margin under a heading that has content right below it | `DesignProperties: ['Spacing': ['margin-bottom': 'S']]` on the heading |
| `SPACE02` | only Atlas spacing values | sides `margin-`/`padding-` `top|right|bottom|left`, values `None S M L`; never a `Class:` or CSS for spacing |
| `SPACE03` | the same vertical spacing on widgets that share a line | give them the same `margin-top`/`margin-bottom` |
| `GRID01` | a column with a filter keeps its `Attribute` | `column colX (Attribute: X) { textfilter fltX (Attribute: X) }`; without it: "Unable to get filter store" |
| `GRID02` | a button changing a grid's rows sits in its header | `controlbar` in the datagrid; `$dgX` or a page parameter |
| `ALERT01` | an alert class on a container, not on inline text | `container ctNote (Class: 'alert alert-info') { dynamictext ... }` |

## lint -- the project's own rules (`mxcli lint`, `.claude/lint-rules/`)

| Code | Wants | Fix |
|---|---|---|
| `UI001` | a data grid filters itself | one filter in the column (`textfilter`, `numberfilter`, `datefilter`, `dropdownfilter`, for an association `(Association: ..., datasource: database ..., CaptionAttribute: ...)`); never a filter bar over a helper entity |
| `MOD001` | documents in process folders, not at module root or in a folder named after a type | `move microflow <Mod>.<Name> to folder '<Process>'` (skill `module-structure`) |
| `REU001` | shared documents shared for real (info, never blocks) | a snippet used by one page is a page section; a `SUB_` with one caller is inline logic (skill `reuse-and-snippets`) |
| `MPR*`, `SEC*`, `CONV*`, `ARCH*`, `QUAL*` | mxcli's built-in rules; errors block, warnings do not | `./mxcli lint -p <app>.mpr --list-rules` names each |
| `CONV011` | a commit inside a loop: one database call per row (warning) | change the objects in the loop, `commit $List;` once after `end loop;`; new objects are `add`ed to a list first |

## naming -- microflows and nanoflows (`check_mdl.py --skill naming`, skill `naming-and-captions`)

| Code | Wants | Fix |
|---|---|---|
| `placeholder-variable` | a name that says what it holds | `$OpenInvoiceCount`, not `$Int1`, `$tmp`, `$x` |
| `type-echo-variable` | no `_List`, `_Object`, `_Obj` suffix | `$OverdueInvoices`, not `$Invoice_List` |
| `REFRESH01` | a microflow that closes its page (a popup's Save) commits with `refresh`, so the grid under the popup shows the new row at once | `commit $Invoice refresh;`, `change $Invoice (...) commit refresh;` -- blocks DONE |
| `PERF02/03/05/06` | a loop that sums rows, queries per row, filters a whole table with `if`, or keeps the maximum (warning) | an OQL view for totals; the condition in XPath; `sort by ... desc limit 1` |
| `action-caption`, `action-caption-is-default`, `decision-caption`, `caption-not-a-question`, `caption-restates-expression`, `loop-annotation`, `caption-on-loop` | a business `@caption` on every action and decision (a question, no `$`), `@annotation` on loops | warnings by default; `MDL_CAPTIONS=error` in `tests/harness.env` makes them block |

## coverage, precheck, the suite and the runtime

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
