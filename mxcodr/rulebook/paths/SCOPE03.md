---
step: paths
level: warn
check: scope_rules.cjs#scopeFindings
key: document
---

# SCOPE03 — nothing in the app is outside the approved requirements

## What it checks
On the finished model: every page and ACT_ microflow of the project's own modules is anchored by an approved requirement, covered by a test that names one, or reached from such a document (a button's microflow, the page it opens, the snippet it places). A helper entity (non-persistent or view, holding totals, a summary or the user's name) is planned when a requirement names it or the page that needs it, and support when a snippet shows it. Support is never flagged: the home and login pages, seed flows, snippets, DS_ and SUB_ flows. It lists what grew past the requirements for the report; nothing is checked while no requirement is recorded.

## Fix
Tie it to the approved requirement it serves (the test that checks that requirement names it on its `# covers:` line), or leave it out and list the idea under "to add next" in the final report.

## Local
# level: warn
# except: Module.Document   # why
