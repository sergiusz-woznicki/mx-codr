---
step: catalog
level: block
check: catalog_rules.cjs#askedViews
key: document
---

# ASKED01 — a calendar, map or chart the request names is on a page

## What it checks
When the person's request (docs/brain/requests/) asks for a calendar, a map or a chart, a page of the app's own modules shows that widget. A dated list in place of a calendar, or a table in place of a chart, is a simplification the person did not agree to.

## Fix
`./mxcli marketplace search "calendar"`, install the widget, put it on the page with the data the person named; when it cannot be installed, say so in the final report.

## Local
# level: block
# except: calendar   # why
