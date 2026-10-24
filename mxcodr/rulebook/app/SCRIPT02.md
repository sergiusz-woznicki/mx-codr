---
step: precheck
level: block
check: role_drops.cjs#roleDropFindings
key: none
---

# SCRIPT02 — no drop of a user role the build needs

## What it checks
A script that drops the user role Administrator (the built-in administrator's role: mxbuild then stops with a NullReference that mx check does not see and the app does not boot), or a user role a demo user still holds (CE1613). A script that creates the role again, or drops or creates the demo user, passes.

## Fix
Leave the drop out, or drop the demo user too.

## Local
# level: block
