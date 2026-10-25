---
step: catalog
level: block
check: catalog_rules.cjs#periodCharts
key: document
---

# CHART01 — a chart of the last N periods shows N labelled periods

## What it checks
When the request asks for a chart of the last N months, weeks or days, no chart takes its bars from a group-by view (a period without rows gets no bar), and no chart labels its x axis with a number, a date or a 'yyyy-MM' text (Plotly draws a date axis).

## Fix
A data-source microflow builds N non-persistent rows, 0 for an empty period, labelled 'MMM yyyy' (mdl-pitfalls.md).

## Local
# level: block
# except: <page>   # why
