---
step: catalog
level: block
check: request_views.cjs#unshownFields
key: document
---

# FIELD01 — the fields the request lists are on the screens

## What it checks
A line of the request (docs/brain/requests/) that lists fields for an entity ("Ticket: number, subject, priority") names attributes of the app's own entities: each one is bound on a page or snippet that shows that entity -- a column of its list, a field of its detail, a `{1}` of a text. An entity no page shows yet is not judged here (OVERVIEW01).

## Fix
Add the field where the entity is shown (`column (Attribute: Priority, Caption: 'Priority')`, a read-only text box) and assert it in that page's test. A field kept off the screens on purpose: say so in the final report.

## Local
# level: block
# except: Module.Entity.Attribute   # why
