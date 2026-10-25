---
step: naming
level: warn
check: event_rules.cjs#eventFindings
key: none
---

# ERR01 — every error handler is noticed, and its log says why

## What it checks
Points out an error handler that nobody would notice: it should log, show a message, raise the error again or return. One that logs names the error itself ($latestError, or $latestHttpResponse after a REST call), not only that something failed.

## Fix
`log error 'Saving {1} failed: {2}' with ({1} = $Ticket/Code, {2} = $latestError/Message);` or `raise error;`; `on error continue` is mxcli's lint CONV014.

## Local
# level: warn
