---
step: catalog
level: warn
check: catalog_rules.cjs#listsWithoutSeed
key: document
---

# SEED01 — a role that only reads a list finds rows in it

## What it checks
A page the menu opens (a menu item or a home page) that lists an entity from the database, for a role that cannot create it (no create access, no microflow it may run that creates one), finds rows the after-startup microflow, or a microflow it calls, creates. The gate rolls the tests' rows back at DONE, so without a seed that role signs in to an empty list and can do nothing about it: a customer with no invoices, a technician with no jobs. A list the role fills itself is not judged, nor accounts, files, or a seed that calls a Java action, a REST service or an import.

## Fix
Create a few realistic rows in the after-startup microflow, only when none exist yet, linked to the demo users who should see them, and return true on every path; no after-startup microflow yet: `alter settings runtime ( AfterStartupMicroflow: 'Module.ASU_Seed' )`. An app that really starts empty: say so in the final report.

## Local
# level: warn
# except: Module.Entity   # why
