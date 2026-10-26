---
step: catalog
level: block
check: request_views.cjs#unshownFields
key: document
---

# FIELD01 — the fields the request lists are on the screens

## What it checks
A line of the request (docs/brain/requests/) lists the fields of an entity ("Ticket: number, subject, priority") and the request asks for a view of it ("the list of tickets", "the ticket details", "a table with columns: ..."): each listed field that is an attribute of the app's own entities is bound on a page or snippet that shows that entity -- a column of its list, a field of its detail, a `{1}` of a text. An entity the request asks no view of, or that no page shows, is not judged: no page is asked for that the request did not name.

## Fix
Add the field where the entity is shown (`column (Attribute: Priority, Caption: 'Priority')`, a read-only text box) and assert it in that page's test. A field kept off the screens on purpose: say so in the final report.

## Local
# level: block
# except: Module.Entity.Attribute   # why
