## Pitfalls that cost sessions the most time

Each one below cost a measured session minutes to forty minutes. Write it right the first time.

- **Current date and time** is the token `[%CurrentDateTime%]`: `addDays([%CurrentDateTime%], -30)`.
  `now()` and `currentDateTime()` do not exist (CE0117 at build time).
- **A token inside `where '...'`**: MDL doubles the single quotes, and the token's `]` stays inside
  them. Write `where '[Mod.Customer_Login = ''[%CurrentUser%]'']'`, not `''[%CurrentUser%'']`.
  In a microflow `retrieve`, the token takes single quotes: `where [id = '[%CurrentUser%]']`.
- **An XPath path alternates association and entity** and ends on the association to compare:
  `'[Mod.Invoice_Customer/Mod.Customer/Mod.Customer_Login = ''[%CurrentUser%]'']'`. "The selected
  entity Mod.X_Y no longer exists" means an association stands where an entity step belongs.
- **A combo box for a reference** takes `Association:`, a data source and a caption, not
  `Attribute:`: `combobox cmbCustomer (Label: 'Customer', Association: Invoice_Customer,
  DataSource: DATABASE Mod.Customer, CaptionAttribute: Name)`.
- **A data grid column across an association** binds the attribute at the end of the path:
  `column colCustomer (Attribute: Invoice_Customer/Name)`, not the association itself.
- **`Administration.Account.Name` does not exist**: Name is System.User's. Show `FullName`.
- **The after-startup microflow returns Boolean**: `returns boolean` and `return true;` (CE0142).
- **A create-object button stays hidden** unless the viewing role may create that entity:
  `grant Mod.Role on Mod.Entity (create, delete, read *, write *)`.
- **Pages and microflows need a role** the moment a menu, a button or another page reaches them
  (CE0557, CE0106): put the `grant view on page` / `grant execute on microflow` in the same
  script that creates them.
- **Two scripts that need each other** (a page calls a new microflow that opens that page) belong
  in one `.mdl`: a script resolves what it creates itself. `--no-check` does not pass the precheck.
- **Model changes go through a `.mdl` file** and `./mxcli exec`: `mxcli -c "grant ..."` is checked
  like a script, and one broken inline rule used to block every later exec.
- **A scenario's result must be captured**: `result=$(scenario '...')`, then `field "$result" x`.
  `scenario '...' > /dev/null` leaves nothing to read. Keep the body single-quoted and pass
  shell values in with `'"$var"'`; no quotes around `$(...)` -- an assignment needs none, and a
  double-quoted body then needs a third closing character that sessions miss.
- **HTTP from a scenario** (an OData or REST test) goes through `page.request.get(url, {headers})`:
  the scenario runner has no Node globals -- no `fetch`, no `Buffer` ("... is not defined").
  Build a Basic-auth header in bash (`auth=$(printf '%s' "$user:$pw" | base64)`) and pass it in.
  A test that only calls an API needs no browser at all: `curl -u "$user:$pw" "$BASE_URL/odata/..."`.
