# Phone, tablet and offline profiles

An offline profile (`PhoneOffline`, `TabletOffline`, `ResponsiveOffline`) is a PWA: the pages and a
local database live on the device, and the user works without a network. Mendix picks a profile by
the device; a test picks it by name.

## Building one

- Logic that runs on the device is a **nanoflow**; a microflow needs the server, so it runs only
  online. `synchronize all;` in a nanoflow behind a button sends the device's changes and fetches
  the server's.
- The profile downloads nothing until each entity has a sync mode:
  `sync ( sync Module.Entity all; sync Module.Other where [Owner = '[%CurrentUser%]']; )` (OFFLINE02).
- **Every user role** needs read access to the synchronized entities, not only the field role:
  mx check says CE2729 otherwise.
- **Who is signed in, offline:** a page the offline profile reaches uses
  `SNIPPET_CurrentUserOffline` (skill spacing-and-layout): a database list of
  `Administration.Account where [id = '[%CurrentUser%]']`, which the profile syncs, and no account
  link. The online snippet's microflow and `ManageMyAccount` link break offline (CE6900, CE6904).
  On a phone page it shares one row with Back and the title (PHONE06; skill spacing-and-layout).
- **Menu items for user management stay on the online profile.** ACCOUNT01/02 do not ask an
  offline profile for them: they would make the Administration pages reachable offline.
- The profile needs **Progressive web app** settings, or no service worker registers and no page
  opens offline (OFFLINE01). mxcli v0.25 creates offline profiles without them, and Studio Pro shows
  them greyed out for an offline profile, so they cannot be set afterwards: stop and ask the person
  to delete the profile in Studio Pro and add it again there, then re-apply its home pages, menu and
  sync with `create or modify navigation` (that leaves the settings alone).
- **Strict mode on Mendix before 11.12.5** breaks every client commit of a synced object: the
  offline save fails with `mx.data.commit is disabled`. There, and only there, turn it off
  (`alter app security ( StrictMode: FALSE );`): STRICT01 then warns instead of blocking. Say in the
  report that 11.12.5 (same LTS) fixes it and strict mode goes back on after that upgrade.
- Atlas's phone and tablet layouts show `Atlas_Core.Phone_Menu`: the template's Home, Layouts,
  Templates and Widgets, which do nothing (PHONE01). Give the app its own menu document with its
  items and Log out, a copy of the layout in the app's module whose `simplemenubar` points at it,
  and `alter page <Page> { set layout = <Module>.Phone_Main };` for the pages only the phone and
  offline profiles open.
- **The browser never gets a phone layout** (PHONE02): a page the Responsive profile opens too
  needs a web copy, `<Page>_Web` on `Atlas_Core.Atlas_Default`, which that profile's home page,
  menu and `_Web` buttons open. Moving the phone's page itself to Atlas_Default fails mx check
  (CE2994: its menu reaches pages that only work online).
- **A phone page lists items as cards, not a data grid** (PHONE03): a grid's columns cut every
  value to a letter and "..." at 390 px. A `listview` whose item is a container with one dynamic
  text per value (the first `RenderMode: H4`, the rest `Paragraph`) on the left and the row's
  buttons on the right (LIST01); the grid's header buttons go above the list. `row_action()` reads
  list views too.
- What only the server may do -- an invoice number, a PDF, a mail -- runs in a microflow after the
  synchronization (an event handler on the synced status), never on the device.

## Testing one

```bash
#!/usr/bin/env bash
# covers: Field.WorkOrder_List, Field.WorkOrder_Edit
set -euo pipefail
source "$(dirname "$0")/lib.sh"

title="Boiler $(date +%s)"
result="$(SV_TITLE="$title" scenario '
  await open_app("PhoneOffline");
  await go_offline();
  await page.click(".mx-name-WorkOrderList_NewButton");
  await landed("WorkOrderEdit_TitleTextBox", "the work order form, offline");
  await fill("WorkOrderEdit_TitleTextBox", vars.TITLE);
  await page.click(".mx-name-WorkOrderEdit_SaveButton");
  await landed("WorkOrderList_OrdersList", "the list after saving offline");
  return {listed: (await page_text()).includes(vars.TITLE)};
')"
[ "$(field "$result" listed)" = "true" ] || fail "the work order saved offline is not on the phone's list"
[ "$(oql_count WorkOrder "Title = '$title'")" = "0" ] || fail "it reached the server while the phone was offline"

# The same page, still loaded: back online, the user presses Sync.
scenario '
  await go_online();
  await sync_now("WorkOrderList_SyncButton");
  return {};
' >/dev/null
[ "$(oql_count WorkOrder "Title = '$title'")" = "1" ] || fail "after syncing, the work order is not on the server"
```

- Sign in online: `open_app("PhoneOffline")` does, then waits for the service worker and loads every
  page module while the network is there. A first sign-in offline is not possible on a real phone
  either.
- **Never reload offline.** `page.goto` and a reload are not served from the worker here; walk on
  with clicks, `menu()` and `fill()`. A new scenario starts online again by itself.
- `sync_now()` fails when no synchronization reached the server: the device is offline, or the
  button does not call a nanoflow with `synchronize`.
- `mxcli run --local` builds without the worker's cache and without the page modules in its
  pre-cache; `open_app` makes up for both. A production package has them already.
