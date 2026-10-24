---
step: layout
level: block
check: layout_rules/offline.cjs#offlineFindings
key: none
---

# OFFLINE01 — offline profile has a service worker

## What it checks
An offline profile works without a network only through the service worker Mendix registers for it. A profile with no Progressive web app settings gets none ("registerServiceWorker": false in the built index.js), and then no page opens offline. mxcli 0.28 writes them with the `progressive web app` clause of `create or modify navigation` (0.27 and before had no syntax, and Studio Pro shows them greyed out for an offline profile, so a profile written there had to be deleted and added again in Studio Pro). Judged where the app is built on this machine (local mode).

## Fix
Add `progressive web app` to the profile.

`create or modify navigation <Profile> progressive web app ( Precaching: true );` -- the clause alone leaves the profile's home pages, menu and sync as they are. Restart the app so it is built again.

## Local
# level: block
