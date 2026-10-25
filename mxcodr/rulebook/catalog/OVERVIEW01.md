---
step: catalog
level: block
check: request_views.cjs#missingOverviews
key: document
---

# OVERVIEW01 — what a role of the request sees is listed in its menu

## What it checks
An entity the request has a role see, view, list or manage ("Agent: can view all tickets", "Requester: sees their own tickets") is listed on a page that role reaches from the navigation: its home page or a menu item (a menu microflow that shows the page counts). "All", "every" or "sees everything" (each entity of the request's data model, not a part of another) asks for an overview: a list from the database that is not tied to an object the page was given.

## Fix
An overview page: a data grid `DataSource: database from Module.Entity` with the fields the request names, a view grant for the role's module role, a menu item before Log out; a test signed in as that role reads its rows.

## Local
# level: block
# except: Module.Entity   # why
