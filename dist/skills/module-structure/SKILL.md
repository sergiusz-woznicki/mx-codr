---
name: module-structure
description: "Whether new functionality belongs in an existing module or a new one, and the folder structure a module starts with — processes, not document types. Use before creating a module, before adding the first documents to one, and when deciding where a new page or microflow goes."
---

# Module structure

Two questions come before any document is created: *is this a new module*, and
*which folder does it go in*. Getting them wrong is cheap today and expensive
later — a module is the unit Mendix secures, versions and (eventually) replaces.

The **mechanics** — `MOVE`, the `folder:` page property, the `folder '...'`
microflow clause — live in [organize-project](../organize-project/SKILL.md). This
skill is the decision, not the syntax.

## When to Use This Skill

- Before `create module`
- Before adding the first pages or microflows to a module
- When new functionality could plausibly go in two places
- When a module has grown and someone suggests splitting it

## When a new module is justified

Mendix's own rule: *"Modules should be treated like standalone replaceable
services; for example, the customer module should function as a standalone customer
management system as much as possible, replaceable by a different customer
management system."*
([dev-best-practices](https://docs.mendix.com/refguide10/dev-best-practices/))

Three triggers, each with the test that settles it:

**1. Business domain / bounded context.** Could this be lifted out and replaced by a
bought system, without the rest of the app noticing anything but a changed
integration? Then it is a module. Invoicing, CRM, Inventory each own their data and
publish what others may use.

**2. Reuse across apps.** Another app or another team would consume it. It becomes
its own module with a deliberate public surface (see *Shared modules* below), not a
folder inside yours.

**3. Integration boundary.** One module per external system — its REST/OData client,
mappings and entities. When the vendor changes, the blast radius is that one module.

### Not reasons to make a module

- *"It is getting big."* Size is a folder problem first. Split when the domain
  splits, not when the document list gets long.
- *"These are all pages."* That is a type, not a boundary.
- *"A different developer wrote it."* Ownership is not a boundary either — two
  people can own two processes in one module.
- *"This entity is only used here."* Then it is already in the right module.

The real ceiling is the app, not the module: roughly 3,000 microflows and 750
entities on a high-end machine (2,000 / 500 on lower spec). Past that, split the
**app**, not the module.

## Folder structure: by process

Mendix documents two options — by process and by entity. **This project uses
process.** Folders name what the business does, and a document sits with the
process it serves:

```
InvoiceDesk/
├── _Setup/          startup, demo data, configuration, test support (data reset)
├── Invoicing/       raise and correct an invoice
├── Chasing/         remind, escalate, write off
├── CustomerAdmin/   maintain customers
└── _Shared/         used by more than one process
```

The rules:

- **Every document lives in a folder.** Nothing at module root. A module root
  full of documents is the state a module decays into, and it decays quickly.
  "Document" here means pages, microflows, nanoflows and snippets — the things
  that carry a process. Entities have no folders (the domain model is one canvas),
  and enumerations, constants and Java actions are not checked.
- **Folder names are processes, never document types.** `Microflows/`, `Pages/`,
  `Snippets/`, `Logic/`, `UI/` are banned: the `ACT_`, `SUB_`, `DS_`, `VAL_`
  prefixes and the document icon already say the type. A type folder splits one
  process across four places for no gain.
- **`_Setup` and `_Shared` carry an underscore** so the two non-process folders sort
  to the top and read as different in kind.
- **A document used by two processes moves to `_Shared/`** — it is never copied.
  If `_Shared` grows past a handful of documents, that is the signal a process is
  hiding in there unnamed.
- **Sub-folders only when a process genuinely has steps.** `Chasing/Escalation/` is
  fine when escalation is several documents; not when it is one.

Consistency beats cleverness: whichever names you pick, every module in the app uses
the same style.

## Shared modules look different

A module other apps consume carries the Marketplace layout instead of processes
([app-setup](https://docs.mendix.com/appstore/creating-content/best-practices/app-setup/)):

```
PaymentsConnector/
├── _Docs/     readme snippet, version constant (semantic version)
├── UseMe/     everything a consumer may call — the public surface
└── Private/   internals consumers must not touch
```

`UseMe` is the contract. If something needs to move out of `Private`, that is a
deliberate act, and a version bump.

## Dependencies between modules

**No cycles.** If A needs B and B needs A, you have one module wearing two names, or
a third module waiting to be extracted. The single documented exception is a
solution module paired with its adaptable counterpart, which Mendix treats as one
module
([sol-architecting](https://docs.mendix.com/appstore/creating-content/sol-architecting/)).

Point the dependency at the more stable side: features depend on the domain, never
the other way round.

Find the violations rather than guessing at them:

```bash
./mxcli graph-report -p app.mpr        # cohesion, "surprise edges", god nodes
./mxcli lint -p app.mpr                # ARCH001: a page reading another module's entities
./mxcli -p app.mpr -c "show impact of Module.Entity"
```

Security follows the same boundary: each user role maps to exactly **one** module
role per module (lint rule CONV008), so a module's roles describe that module's
access and nothing else.

## Starting a new module

1. Name it for the domain, UpperCamelCase, no `Module` suffix: `Invoicing`, not
   `InvoiceModule`.
2. Create the process folders **before** the first document — `_Setup`, `_Shared`,
   and one per process you already know about.
3. Create one module role per level of access, and map each to a single user role.
4. Put the entities the module owns in its own domain model; reach into another
   module's entities only through that module's microflows.

## Check it

```bash
./mxcli lint -p app.mpr | grep -E 'MOD001|ARCH001|CONV008'
./mxcli graph-report -p app.mpr
```

`MOD001` — a page, microflow, nanoflow or snippet at module root, or in a folder
named after a document type. `ARCH001` — a page reading another module's entities.
`CONV008` — a module role mapped to more than one user role. `graph-report` shows
cycles and cross-module coupling that no single rule catches.

## Validation checklist

- [ ] Every new module answers yes to domain, reuse, or integration boundary
- [ ] No document sits at module root
- [ ] No folder is named after a document type
- [ ] Shared documents live in `_Shared/`, not duplicated
- [ ] A consumable module exposes `UseMe/` and hides `Private/`
- [ ] No cyclic dependency between modules (`graph-report`, ARCH001)
- [ ] `./mxcli lint -p app.mpr` clean for the module, CONV008 included
