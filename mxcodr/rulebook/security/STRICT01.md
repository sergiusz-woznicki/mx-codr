---
step: security
level: block
check: security_rules.cjs#strict01
key: none
---

# STRICT01 — strict mode is on

## What it checks
Strict mode is on. Without it, a clever user can read and change data through the browser in ways the pages never offer. In an app with an offline profile on Mendix before 11.12.5 it only warns: there strict mode breaks every client commit of a synced object ("mx.data.commit is disabled"), fixed in 11.12.5.

## Fix
`alter app security ( StrictMode: TRUE );`.

## Local
# level: block

