# layout -- the shape of a signed-in app (skill `spacing-and-layout`)

One line per code of the `layout` step; every code blocks DONE unless marked warning. The card: `tests/rulebook/layout/<CODE>.md`.

| Code | Wants | Fix |
|---|---|---|
| `ACCOUNT01` | a Users menu item for administrators | `menu item 'Users'` showing `Administration.Account_Overview`. |
| `ACCOUNT02` | a My account menu item | `menu item 'My account'` calling `Administration.ManageMyAccount`. |
| `ACCOUNT03` | every signing-in role has Administration.User | `alter user role <Role> add module roles (Administration.User);`. |
| `ALERT01` | warning: an alert class on a container, not on inline text | `container ctNote (Class: 'alert alert-info') { ... }` |
| `BACK01` | a Back button, top left, on a page another page opens | In the finding. |
| `DATE01` | a grid shows the time a form edits | In the finding. |
| `EDGE01` | every widget sits inside a layout grid | A `layoutgrid` around the page's widgets, the top row too. |
| `GRID01` | a column with a filter keeps its Attribute | `column colX (Attribute: X) { textfilter fltX (Attribute: X) }`. |
| `GRID02` | a button that changes a grid's rows sits in its header | `controlbar` in the datagrid; `$dgX` or a page parameter. |
| `HEAD01` | warning: a heading on every page |  |
| `HIDDEN01` | no never-shown widget | Remove it; prove access with `oql_count` in the test. |
| `HOME01` | administrators open on a page of the app's own module | `home page <Module>.Admin_Home for Administrator`. |
| `ICON01` | an icon on every button | `Icon: 'Atlas_Core.Atlas_Filled.floppy-disk'`; `trash-can`, `pencil`, `add`. |
| `LABEL01` | captions are words | `Caption: 'Due date'`, not the attribute's name. |
| `LAYOUT01` | one layout for every page that is not a pop-up | One (`Atlas_Core.Atlas_Default`) on every page. |
| `LIST01` | a list item: texts left, buttons right | In the finding. |
| `MODULE01` | MyFirstModule gone once the app has a module | Re-point home pages and roles; `drop module MyFirstModule;`. |
| `NAME01` | warning: a widget name is used on one page only | Its own `<Page>_<What><Type>` name. |
| `NAME02` | warning: every widget is named <Page>_<What><Type> | The name it prints; rename `.mx-name-...` in tests too. |
| `NAV01` | users can log out | `menu item 'Log out' (OnClick: sign out)` last, icon `logout`. |
| `NAV02` | warning: Log out is the last menu item | Move it to the end. |
| `NAV03` | every role's home page is in the menu | `menu item '<caption>' ( OnClick: show page <Page> )` before Log out. |
| `NAV04` | no menu built from buttons in a layout | Those pages go in the profile's menu. |
| `NAV05` | an icon on every menu item | `Icon: Atlas_Core.Atlas_Filled.<name>` at the end of the item. |
| `NAV06` | no icon twice in what one role sees | The other icon the message suggests. |
| `OFFLINE01` | an offline profile has a service worker | The person re-adds it in Studio Pro. |
| `OFFLINE02` | an offline profile syncs entities | `sync Module.Entity all;` in its sync block. |
| `OFFLINE03` | a test goes offline | `go_offline()`, `go_online()`, `sync_now()`. |
| `PHONE01` | phone layouts show the app's menu | In the finding. |
| `PHONE02` | the browser never gets a phone layout | In the finding. |
| `PHONE03` | a phone page lists items as cards | In the finding. |
| `PHONE04` | a phone's bar stays on screen | In the finding. |
| `PHONE05` | the login form fits a phone | In the finding. |
| `PHONE06` | phone: Back, title, user in one row | In the finding. |
| `SPACE01` | a margin after an inline widget and under a heading | `('Spacing': ('margin-bottom': 'S'))` on the heading. |
| `SPACE02` | Atlas spacing only (None, S, M, L) | Atlas `margin-`/`padding-` sides, `None S M L`; no `Class:`. |
| `SPACE03` | the same vertical spacing on widgets that share a line | Give them the same `margin-top`/`margin-bottom`. |
| `SPACE04` | a gap above a grid, list or card | `'margin-bottom': 'S'` on the upper one; each `controlbar` button too |
| `TABS01` | warning: a phone page tabs its object and its list | In the finding. |
| `TEXT01` | a text area for a long String | `replace txtX with { textarea txtX (...) }`. |
| `TEXT02` | warning: a text area for a prose-named attribute | A textarea if people write more than a line. |
| `URL01` | every page that can have a URL has one | In the finding; the same `Url:` in the page's create. |
| `USER01` | who is signed in, top right, on every page | The finding prints it. |
