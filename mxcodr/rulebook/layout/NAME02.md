---
step: layout
level: warn
check: layout_rules/names.cjs#nameFindings
key: document
baseline: names
---

# NAME02 — every widget is named <Page>_<What><Type>

## What it checks
Every widget is named after its page, what it is for and its type, in full words, like OrderDetail_GenerateInvoiceButton. Tests find widgets by these names. The precheck asks for them before each exec; the gate blocks a page the app did not have when the harness was installed, and only warns about one it had.

## Fix
The name it prints, in the tests too.

## Local
# level: warn
# except: Module.Document   # why

