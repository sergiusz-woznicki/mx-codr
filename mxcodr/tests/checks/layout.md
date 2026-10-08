# layout -- the shape of a signed-in app (`tests/gate.sh`, skill `spacing-and-layout`)

One line per code the `layout` step prints. Every code blocks DONE unless its line says "warning". All: `.mxcli/layout.txt`.

| Code | Wants | Fix |
|---|---|---|
| `NAV01` | a way to log out once users sign in | `menu item 'Log out' ( OnClick: sign out, Icon: Atlas_Core.Atlas_Filled.logout )` as the menu's last item |
| `NAV02` | warning: Log out last in the menu | move it to the end |
| `NAV03` | every role's home page in the menu | `menu item '<caption>' ( OnClick: show page <Page>, Icon: <icon> )` before Log out |
| `NAV04` | no hand-built menu of link buttons in a layout | put those pages in the navigation profile's menu; the layout keeps Atlas's own menu |
| `NAV05` | an icon on every menu entry | `Icon: Atlas_Core.Atlas_Filled.<name>` at the end of the item |
| `NAV06` | no icon twice in what one role sees | the other icon the message suggests |
| `HOME01` | administrators open on a page of the app's own module | create `<Module>.Admin_Home` and `home page <Module>.Admin_Home for Administrator` |
| `ACCOUNT01` | a Users item for administrators | `menu item 'Users' ( OnClick: show page Administration.Account_Overview, Icon: ... )` before Log out |
| `ACCOUNT02` | a My account item | `menu item 'My account' ( OnClick: call microflow Administration.ManageMyAccount, Icon: Atlas_Core.Atlas_Filled.user )` before Log out |
| `ACCOUNT03` | every signing-in role can open My account; someone can manage users | `alter user role <Role> add module roles (Administration.User);` and `Administration.Administrator` on the administrators' role |
| `MODULE01` | `MyFirstModule` gone once the app has its own module | re-point home pages, drop `MyFirstModule.User` from user roles, `drop module MyFirstModule;` |
| `USER01` | who is signed in, top right, on every page | the page starts with `container ctPageTop (DesignProperties: ('Flex container': 'Horizontal (row)', 'Align items X': 'Right'))` holding `snippetcall scCurrentUser (Snippet: <Module>.SNIPPET_CurrentUser)`; with Back, `'Space between (only for horizontal containers)'` |
| `BACK01` | Back, top left, on every page another page or microflow opens | first widget `actionbutton btnBack (Caption: 'Back', Action: close page, Icon: 'Atlas_Core.Atlas_Filled.chevron-left')`; pop-ups excepted |
| `ICON01` | an icon on every button | `Icon: 'Atlas_Core.Atlas_Filled.floppy-disk'` Save, `trash-can` Delete, `pencil` Edit, `add` New, `view` Open |
| `LAYOUT01` | one layout for every page that is not a pop-up | pick one (`Atlas_Core.Atlas_Default`) and set it on every page |
| `EDGE01` | widgets inside a layout grid | `layoutgrid pageGrid { row rowTop { column colTop (DesktopWidth: 12) { ... } } }` around the page's widgets, the top row too |
| `SPACE01` | a margin under a heading that has content right below it | `DesignProperties: ('Spacing': ('margin-bottom': 'S'))` on the heading |
| `SPACE02` | only Atlas spacing values | sides `margin-`/`padding-` `top|right|bottom|left`, values `None S M L`; never a `Class:` or CSS for spacing |
| `SPACE03` | the same vertical spacing on widgets that share a line | give them the same `margin-top`/`margin-bottom` |
| `SPACE04` | a gap between a button or text and a grid, list or card above or below it | `'margin-bottom': 'S'` on the upper one; each `controlbar` button too |
| `GRID01` | a column with a filter keeps its `Attribute` | `column colX (Attribute: X) { textfilter fltX (Attribute: X) }`; without it: "Unable to get filter store" |
| `GRID02` | a button changing a grid's rows sits in its header | `controlbar` in the datagrid; `$dgX` or a page parameter |
| `ALERT01` | warning: an alert class on a container, not on inline text | `container ctNote (Class: 'alert alert-info') { dynamictext ... }` |
| `NAME01` | warning: a widget name on one page only | its own `<Page>_<What><Type>` name |
| `NAME02` | `<Page>_<What><Type>`: `OrderDetail_GenerateInvoiceButton` | the name it prints; warns until the first DONE, then blocks a new or changed page. Rename `.mx-name-...` in tests too |
| `TEXT01` | a textarea for a String over 500 or unlimited | `replace txtX with { textarea txtX (...) }` |
| `TEXT02` | warning: a textbox on a prose-named attribute (Notes, Reason) of 100+ | a textarea if people write more than a line |
| `URL01` | a URL on every non-pop-up page with no non-persistent parameter | the `alter page` it prints; the same `Url:` in the page's create |
