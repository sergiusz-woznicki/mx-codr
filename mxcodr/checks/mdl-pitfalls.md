## Pitfalls that cost sessions the most time

Each one below cost a measured session minutes to forty minutes. Write it right the first time.

- **Current date and time** is the token `[%CurrentDateTime%]`: `addDays([%CurrentDateTime%], -30)`.
  `now()` and `currentDateTime()` do not exist (CE0117 at build time).
- **An XPath is written in `[ ]`, in a grant as in a `retrieve`**, and a token inside it takes plain
  single quotes: `where [Mod.Customer_Login = '[%CurrentUser%]']`. (Before mxcli 0.25 a grant's XPath
  went in `'...'` with doubled quotes; that still parses but warns MDL-DEPR030.)
- **An XPath path alternates association and entity** and ends on the association to compare:
  `[Mod.Invoice_Customer/Mod.Customer/Mod.Customer_Login = '[%CurrentUser%]']`. "The selected
  entity Mod.X_Y no longer exists" means an association stands where an entity step belongs.
- **A combo box for a reference** takes `Association:`, a data source and a caption, not
  `Attribute:`: `combobox cmbCustomer (Label: 'Customer', Association: Invoice_Customer,
  DataSource: database Mod.Customer, CaptionAttribute: Name)`.
- **A data grid column across an association** binds the attribute at the end of the path:
  `column (Attribute: Invoice_Customer/Name)`, not the association itself. A data grid column has no
  name in Mendix: `column (...)`, addressed later as `dg column(Name)` (a name warns MDL-DEPR005).
- **`Administration.Account.Name` does not exist**: Name is System.User's. Show `FullName`.
- **A user's roles are the reference set `UserRoles`, not an attribute**: `retrieve $Role from System.UserRole
  where [Name = 'Customer'] first;` then `change $User (UserRoles = $Role);` (`UserRole` does not exist, CE1613).
- **`create module Shop;` takes nothing else**: no `( Description: ... )` and no `description '...'`.
- **No `commit` inside a `loop`** (lint CONV011: one database call per row). Change the objects in
  the loop and commit the list once after it: `change $Line (Done = true);` in the loop, then
  `commit $Lines;` after `end loop;`. A new object goes into a list first (`$New = create list of
  Mod.Line;` before the loop, `add $Copy to $New;` in it, `commit $New;` after it).
- **Totals and counts over many rows come from an OQL view**, not a loop (gate PERF02/03/05/06). One view
  computes them in one query: `create or modify view entity Sales.CustomerTotals (CustomerName: String(200),
  OrderCount: Integer) as (select c.Name as CustomerName, (select count(o.ID) from Sales."Order" as o
  where o/Sales.Order_Customer = c.ID) as OrderCount from Sales.Customer as c);` plus a grant with an XPath.
  Measured at 10k rows: view 60 ms, loop 160 ms, `count()`/`sum()` after a retrieve 159 ms. Filter in the
  retrieve, not with an `if` in a loop: `retrieve $Due from Sales.Invoice where [Status != 'Paid'];`. The
  highest value (the next number) is one sorted row: `retrieve $Last from Sales.Invoice where
  [Number != empty] sort by Sales.Invoice.Number desc first;` -- `first` binds one object; since mxcli
  0.25 `limit 1` under `mdl 1;` is a list of one. A role that sees only its own rows
  must not read the view unconstrained (gate VIEW01): constrain the grant, or revoke it and read the
  view in the page's data-source microflow, filtered to the object it was given.
- **Index what you filter or sort on** (gate PERF07): Mendix indexes only `id`, associations and unique
  attributes. One index per query, its `=` attributes first, then the range or sort:
  `alter entity Sales.Invoice add index if not exists (PaymentStatus, DueDate);` -- at 200k rows the newest
  row of one status: 9.9 ms without, 2.6 ms with two single indexes, 0.01 ms with that one. It also serves
  a query on PaymentStatus alone, so drop the old (PaymentStatus) and any index no query needs (PERF08).
  Not booleans, `!=` or `contains()`; each index costs a little on commit.
- **A popup's Save commits with `refresh`**: `commit $Invoice refresh;` then `close page;`.
  Without it the grid under the popup shows the old rows until a reload (gate code REFRESH01).
- **A list takes its rows from the database, not from a flow that only retrieves them** (gate DS01):
  `datagrid OrderDetail_LinesGrid (DataSource: database Shop.OrderLine where [Shop.OrderLine_Order = $Order])`;
  inside a data view the enclosing object is `'[%CurrentObject%]'`. The database pages, sorts and
  filters; a flow's list goes to the client whole. Keep a flow only for what an XPath cannot say.
- **An event handler never commits its own object with events** (gate EVENT01: it runs itself until
  the app crashes): `commit $Order without events;`, or, before commit, only change it. A before
  handler that can return false needs `raise error`, or the save is skipped in silence (EVENT02):
  `alter entity Shop.Order add event handler on before commit call Shop.BCO_Order($currentObject) raise error;`.
  A bare `commit $X;` runs the handlers; `without events` skips them (EVENT03 warns).
- **The after-startup microflow returns Boolean**: `returns boolean` and `return true;` (CE0142).
- **A create-object button stays hidden** unless the viewing role may create that entity:
  `grant create, delete, read *, write * on entity Mod.Entity to Mod.Role;`.
- **A user filling in an object a microflow created needs `write`, not `create`**: the
  microflow creates it, the page edits it. Grant only the fields the page leaves editable,
  `grant read *, write (Quantity, OrderLine_Product) on entity Mod.OrderLine to Mod.Customer;`
  -- a `create` right adds lint CONV006 and nothing the page needs.
- **Pages and microflows need a role** the moment a menu, a button or another page reaches them
  (CE0557, CE0106): put the `grant view on page` / `grant execute on microflow` in the same
  script that creates them.
- **Two scripts that need each other** (a page calls a new microflow that opens that page) belong
  in one `.mdl`: a `show page` or a button may name what the script creates further down. A `call
  microflow` may not: create the called microflow first. `--no-check` does not pass the precheck.
- **Model changes go through a `.mdl` file** and `./mxcli exec`: `mxcli -c "grant ..."` is checked
  like a script, and one broken inline rule used to block every later exec.
- **A scenario's result must be captured**: `result=$(scenario '...')`, then `field "$result" x`.
  `scenario '...' > /dev/null` leaves nothing to read. Keep the body single-quoted and pass shell
  values in as `SV_<NAME>`: `result=$(SV_PW="$pw" SV_INVOICE=INV-0002 scenario '... vars.PW ...')`
  -- never splice `'"$var"'` into the body, and no quotes around `$(...)` (an assignment needs none).
  No apostrophe anywhere in that body, comments included: `// the module's page` ends the quoted JS
  and bash refuses the whole script.
- **HTTP from a scenario** (an OData or REST test) goes through `page.request.get(url, {headers})`:
  the scenario runner has no Node globals -- no `fetch`, no `Buffer` ("... is not defined").
  Build a Basic-auth header in bash (`SV_AUTH=$(printf '%s' "$user:$pw" | base64)`), use vars.AUTH.
  A test that only calls an API needs no browser at all: `curl -u "$user:$pw" "$BASE_URL/odata/..."`.
- **An enumeration in a microflow signature is `Enumeration(Mod.Enum)`**, parameter and return alike:
  `($Status: Enumeration(Mod.OrderStatus)) returns Enumeration(Mod.OrderStatus)`. Written as
  `Mod.OrderStatus` it fails with "entity 'Mod.OrderStatus' not found" (two sessions, four execs each).
- **An activity's result is never declared**: `$Next = call microflow ...;`, `$Rows = retrieve ...`,
  `$Obj = create ...` make the variable; a `declare $Next` before it is CE0111 "Duplicate variable name".
- **String functions**: `replaceAll(s, 'x', 'y')`, `urlEncode(s)`, `toLowerCase`, `trim` -- there is no
  `replace()` (CE0117). A path parameter that holds `/` (an order number) goes through `urlEncode`.
- **A specialisation of `System.FileDocument` or `System.Image`** takes no `write *` (CE6592, the system
  attribute HasContents): grant `read *` and `write` on your own attributes only.
- **A non-persistent object a page shows or a flow hands to a page** needs `grant create, read *,
  write * on entity Mod.Entity to Mod.Role;`, or the client fails with "cannot create Mendix object"
  (CE2729 at check).
- **Every statement in an owner script is re-runnable** (each form checked on mxcli 0.25): `create or
  modify` for module, entity, view entity, enumeration, page, microflow, java action, user role and
  module role;
  `drop user role if exists`, `drop demo user if exists`, `create persistent entity if not exists`,
  `alter entity X add attribute if not exists ...`, `alter entity X add event handler if not exists on
  before commit call Mod.MF raise error`. There is no `drop module if exists` and no `drop entity|page|
  microflow if exists`: a plain `create` or an unguarded `drop` stops the second exec at "already
  exists" / "not found" -- put a one-off `drop module` in its own script.
- **Demo user passwords are 12+ characters** with a digit (the template's policy); a shorter one stops
  the exec at "password policy violation".
- **A data source microflow does not apply entity access**: an XPath rule that scopes a customer to
  their own rows does not reach what the microflow retrieves. Constrain the retrieve itself --
  `where [Mod.Invoice_Customer = $SignedInCustomer]` or the `'[%CurrentUser%]'` path (gate `SCOPE01`).
