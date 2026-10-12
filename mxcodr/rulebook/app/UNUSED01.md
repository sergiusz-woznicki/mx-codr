---
step: unused
level: block
check: check_unused.cjs#findings
key: document
---

# UNUSED01 — nothing is left that nothing uses

## What it checks
No microflow, page, snippet, enumeration or Java action is left that nothing uses. It is reported only if nothing in the app refers to it, its name appears nowhere else, and the app still builds without it.

## Fix
The `drop` lines given, plus its `mdlsource/` source and `# covers:` name; to keep one: `except:` in ## Local.

## Local
# level: block
# except: Module.Document   # why

