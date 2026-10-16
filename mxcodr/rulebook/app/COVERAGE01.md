---
step: coverage
level: block
check: check_test_coverage.cjs#moduleReport
key: none
---

# COVERAGE01 — every page and ACT_ microflow is on a test's # covers: line

## What it checks
Every page and every ACT_ microflow has a test. A test says which pages and microflows it tests in a comment at its top, # covers: Order_List, ACT_Order_Save. This rule checks that every page and ACT_ microflow appears in such a comment, and that every name in those comments really exists in the app (a renamed page leaves an old name behind).

## Fix
Comma- or space-separated; a `SUB_`, entity or enumeration does not count.

## Local
# level: block

