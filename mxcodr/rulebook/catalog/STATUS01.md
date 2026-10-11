---
step: catalog
level: warn
check: catalog_rules.cjs#repeatStatusButtons
key: document
---

# STATUS01 — a button that sets one status is gone once the object has it

## What it checks
A button whose microflow or nanoflow always sets the same status (Send invoice sets Sent, Finish job sets Finished) is hidden once the object has that status, so nobody sets it a second time. A button that walks through several statuses, or sets a computed one, is not judged.

## Fix
`alter page Mod.Invoice_Detail { set Visible = [Status != Mod.InvoiceStatus.Sent] on InvoiceDetail_SendButton };` and the same `Visible:` in the script that creates the page; the flow checks the status too.

## Local
# level: warn
# except: Module.Document   # why
