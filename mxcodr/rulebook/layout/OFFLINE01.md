---
step: layout
level: block
check: layout_rules/offline.cjs#offlineFindings
key: none
---

# OFFLINE01 — an offline profile has a service worker

## What it checks
An offline profile works without a network only through the service worker Mendix registers for it. A profile with no Progressive web app settings gets none ("registerServiceWorker": false in the built index.js), and then no page opens offline. mxcli v0.25 writes offline profiles without these settings, and Studio Pro shows them greyed out for an offline profile, so they cannot be set afterwards: the profile has to be deleted and added again in Studio Pro. Judged where the app is built on this machine (local mode).

## Fix
Person: re-add the profile in Studio Pro.

## Local
# level: block
