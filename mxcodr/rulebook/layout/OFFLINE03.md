---
step: layout
level: block
check: layout_rules/offline.cjs#offlineFindings
key: none
---

# OFFLINE03 — a test goes offline

## What it checks
An app with an offline profile has a test that cuts the network: it opens the profile, calls go_offline(), does the work the user does without a network, checks the server has nothing yet, then go_online() and sync_now() and checks it arrived.

## Fix
`go_offline()`, then `go_online()` and `sync_now()`.

## Local
# level: block
