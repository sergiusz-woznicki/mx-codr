---
step: layout
level: block
check: layout_rules/offline.cjs#phoneMenuFindings
key: none
---

# PHONE01 — phone layouts show the app's own menu

## What it checks
Atlas's phone and tablet layouts show a bottom menu from Atlas_Core (Phone_Menu, Tablet_Menu): the template's Home, Layouts, Templates and Widgets, which do nothing. A page whose layout shows a menu whose items all do nothing is reported.

## Fix
The finding prints it.

## Local
# level: block
