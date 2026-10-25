---
step: naming
level: warn
check: naming_rules.cjs#actionFindings
key: none
baseline: captions
---

# CAPTION09 — a caption says more than its line

## What it checks
No call caption is the called flow's name ("Run send reminder" over a call of SUB_Reminder_Send), no commit or retrieve caption a stock verb with its own variable or entity ("Save the ticket" over `commit $Ticket`), no caption a stock phrase ("Work out the value") or a hint's `<slot>` left unfilled. Listed after each exec; refused at DONE in a script the exec applied.

## Fix
Say why it runs for the person: 'Mark the ticket as resolved', 'Record who closed the ticket'.

## Local
# level: warn
