# The menu (skill spacing-and-layout)

## The main menu: Log out once users can sign in

The navigation menu frames every screen. As soon as the app has user accounts that
sign in (customer logins, demo users, an Administration account page), its main menu
ends with a **Log out** item, in every navigation profile those users reach. Without
it a user can only end the session by closing the browser.

```sql
create or modify navigation Responsive
  home page MyFirstModule.Home_Web
  {
    menu item 'Invoices' ( OnClick: show page Invoicing.Invoice_Overview, Icon: Atlas_Core.Atlas_Filled.document )
    menu item 'Log out' ( OnClick: sign out, Icon: Atlas_Core.Atlas_Filled.logout )
  }
;
```

`sign out` needs no page or microflow, and it is always the **last** item.
`create or modify navigation` replaces the whole menu: `DESCRIBE NAVIGATION Responsive`
first and keep the items already there.

The gate's layout verdict fails (`NAV01`) while security is on and no menu, page or
snippet offers a way to log out.

## One menu for every role

The menu is the **navigation profile's** menu, shown by `Atlas_Core.Atlas_Default`:
a sidebar on a wide screen, a hamburger button that opens it on a phone, the current
page highlighted. Nothing else gives an app that for free.

Different roles do **not** need different menus. Mendix hides a menu item from a
user who cannot open its page, so a single menu lists every page and each role sees
only its own. What a role can open is page access; where it lands is its home page:

```sql
grant view on page Sales.Order_List to Sales.Employee;
grant view on page Sales.Cust_MyOrders to Sales.Customer;

create or modify navigation Responsive
  home page Sales.Order_List
  home page Sales.Order_List for Employee
  home page Sales.Cust_MyOrders for CustomerPortal
  {
    menu item 'Orders' ( OnClick: show page Sales.Order_List, Icon: Atlas_Core.Atlas_Filled."shopping-cart" )
    menu item 'My orders' ( OnClick: show page Sales.Cust_MyOrders, Icon: Atlas_Core.Atlas_Filled.document )
    menu item 'Log out' ( OnClick: sign out, Icon: Atlas_Core.Atlas_Filled.logout )
  }
;
```

An employee sees Orders and Log out; a customer sees My orders and Log out.

Never build the menu yourself — a layout of your own with link buttons to pages, one
per role. A session did exactly that because MDL menu items take no roles: the links
ran together into one line of text, a fixed 232 px panel covered half a phone
screen, and there was no hamburger and no highlighted page. Keep the pages on
`Atlas_Core.Atlas_Default` (or another stock Atlas layout) and put them in the menu.

Every menu entry — item or sub-menu, Log out included — has an **icon that shows
what it opens**: with the sidebar collapsed the icon is all a user sees. Take it
from `Atlas_Core.Atlas_Filled` (`DESCRIBE ICON COLLECTION Atlas_Core.Atlas_Filled`
lists the names; hyphenated ones are double-quoted). Ones that fit common screens:

| Screen | Icon |
|---|---|
| orders, cart | `Atlas_Core.Atlas_Filled."shopping-cart"` |
| customers, contacts | `Atlas_Core.Atlas_Filled."user-neutral-group"` |
| users (user management) | `Atlas_Core.Atlas_Filled."user-neutral-shield"` |
| My account | `Atlas_Core.Atlas_Filled.user` |
| invoices, bills | `Atlas_Core.Atlas_Filled."cash-payment-bill"` |
| dashboard, overview | `Atlas_Core.Atlas_Filled.dashboard` |
| reports | `Atlas_Core.Atlas_Filled."analytics-bars"` |
| shipments, products | `Atlas_Core.Atlas_Filled."shipment-box"` |
| tasks, approvals | `Atlas_Core.Atlas_Filled."task-list-multiple"` |
| documents | `Atlas_Core.Atlas_Filled.document` |
| setup, settings | `Atlas_Core.Atlas_Filled.cog` |
| home | `Atlas_Core.Atlas_Filled.home` |
| Log out | `Atlas_Core.Atlas_Filled.logout` |

Two items with the same icon read as the same screen; pick different ones. The gate fails
`NAV06` when two entries one role sees share an icon -- only the entries that role may open
count, since Mendix hides the rest.

The gate fails `NAV03` when a role's home page is not in the menu, and `NAV04` when
one of the project's own layouts opens two or more pages from buttons.

## Users and "My account" in the menu

Once users sign in, the menu also carries the Administration module's own account screens.
Nothing needs building, and nothing in the Marketplace module changes:

```sql
    menu item 'Users' ( OnClick: show page Administration.Account_Overview, Icon: Atlas_Core.Atlas_Filled."user-neutral-shield" )
    menu item 'My account' ( OnClick: call microflow Administration.ManageMyAccount, Icon: Atlas_Core.Atlas_Filled.user )
    menu item 'Log out' ( OnClick: sign out, Icon: Atlas_Core.Atlas_Filled.logout )
```

- **Users** (`Account_Overview`) is user management: create accounts, reset passwords,
  assign roles. Only `Administration.Administrator` may open it, so only administrators
  see the item — the one-menu rule does the rest.
- **My account** is every user's own account and password. The page behind it,
  `Administration.MyAccount`, needs the account as its parameter, so a menu item cannot open
  it; `ManageMyAccount` fetches the signed-in account and opens it.
- Every user role that signs in includes `Administration.User` (without it "My account" is
  hidden), and the administrators' role includes `Administration.Administrator`:
  `alter user role Employee add module roles (Administration.User);`

The gate fails `ACCOUNT01` (no Users item), `ACCOUNT02` (no My account item) and `ACCOUNT03`
(a role without `Administration.User`, or nobody with `Administration.Administrator`).

