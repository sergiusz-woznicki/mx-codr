---
step: paths
level: block
check: requirement_rules.cjs#requestFindings
key: document
---

# REQ04 — the requirements keep what the request spells out

## What it checks
Each line of the newest request in docs/brain/requests/ that holds a number with its noun, a quoted caption, a format (`DD/MM/YYYY`), a bound (`>0`) or one of the words exactly, unique, default, disabled, read-only, mandatory, above, below, finds it again in a requirement or an assumption of docs/brain/plan. A detail kept only by an assumption that gives it up (instead of, without, hidden, simplified, or a harness rule code as the reason) is only a warning, and a clean one when the assumption carries the platform's proof: the mx check or runtime error text, a CE code. A harness rule code is no proof: the rules allow the form the request asks for (a filter bar above a grid is its controlbar, card GRID03).

## Fix
`./mxcli brain capture "<requirement>" --slice <slice>` with the detail in it and a "checked when" that asserts it, then promote it (a capture that repeats the request passes the scope freeze). Built differently: `Assumed: ...` --open, naming the detail and the platform error that stopped you; a rule code that seems to refuse it: read its card and build the form it allows.

## Local
# level: block
# except: <key>   # why
