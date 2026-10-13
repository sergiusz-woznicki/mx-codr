---
step: layout
level: block
check: layout_rules/dates.cjs#dateColumnFindings
key: none
---

# DATE01 — a grid shows the time a form edits

## What it checks
A data grid column bound to a DateTime shows its time of day when a form of the app edits that time (a datepicker with DateFormat: DateTime or Time, or a CustomDateFormat with hours or minutes). Data grid 2 shows a DateTime as a date only, so a booking from 10:00 to 11:00 reads as two equal dates.

## Fix
In the finding.

Full column: `column (Attribute: StartsAt, Caption: 'Starts', ShowContentAs: dynamicText, Content: '{1}', ContentParams: ({1} = formatDateTime($currentObject/StartsAt, 'd MMM yyyy, HH:mm')))`.
The `$currentObject/` path is required; a bare attribute is CE0117.

## Local
# level: block
