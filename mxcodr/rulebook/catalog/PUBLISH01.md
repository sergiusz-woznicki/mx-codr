---
step: catalog
level: block
check: catalog_rules.cjs#unpublishedEvents
key: document
---

# PUBLISH01 — a business event the app publishes is really published

## What it checks
A business event service of the app's own modules that publishes a message: some microflow hands the message's entity to a Java action (the module's publish action, or a wrapper of the app's own). Creating the event object and logging it is not publishing -- consumers never receive it.

## Fix
mxcli 0.26 cannot write `BusinessEvents.PublishBusinessEvent_V2` (CE0115): a Java action of your own that publishes (pitfalls); test that it ran.

## Local
# level: block
# except: Module.Service   # why
