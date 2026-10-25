---
step: naming
level: warn
check: naming_rules.cjs#escapeFindings
key: none
---

# TEXT03 — no backslash escape in a string

## What it checks
A backslash is no escape in an MDL string: `'a\nb'` is four characters. A text built with `\n`, `\r` or `\t` shows them as they are (a generated document came out as one line). Lines that build a pattern are left alone.

## Fix
Build the lines in the Java action that makes the document.

## Local
# level: warn
