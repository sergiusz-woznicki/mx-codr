---
name: requirements-interview
description: "Ask the person what the app must do before building it: who uses it, what each role sees and changes, the journeys, phone or offline, outside systems, and what counts as done -- then record each answer as a requirement in the project brain. Use before the first feature of a new app, and before a change that adds a role, a module or a channel (phone, offline, an integration), when the request leaves those open."
---

# Ask before you build

A short request ("make me an invoice chasing app") leaves most of the app open. Whatever you
guess there, the person corrects after DONE, and that is the most expensive rework. Ask first,
record the answers as requirements, then build them test-first (skill `test-first-delivery`).

## 0. Should you ask at all?

Run `bash tests/orient.sh` and read its `requirements:` line:

- `ask` (the default): ask the person, and wait for the answers.
- `assume`: nobody will answer (a benchmark, an unattended run). Do every step below, but take
  your recommended answers as assumptions and go on without waiting. A request that says not to
  ask means the same. Never end a turn on a plan, a question or "say go": nobody reads it, and the
  run stops there with nothing built. Record the assumptions and write the first test in the same
  turn; the turn ends at DONE, or at a step only the person can take.
- `off`: skip this skill.

Skip it as well when the request already answers every branch below, or when the change adds no
role, module or channel. `./mxcli brain plan -p <app>.mpr` shows the requirements already recorded:
ask only about what is new.

## 1. The questions: one fixed tree

Check the request against these branches. Every branch it leaves open is a question.

1. **Who uses it:** the user roles; what each one may see and change; seeded users or sign-up.
2. **The data:** the main entities and their key attributes; what is required, what is unique.
3. **The journeys:** per role, the pages and actions in the order the user meets them.
4. **Channels:** browser, phone, offline -- and then what syncs, and when.
5. **Outside world:** imports, REST or OData, e-mail, files.
6. **Security:** Production level (the harness wants it); the demo users and their passwords.
7. **Done:** per journey, what the person checks to call it done.

## 2. Ask in rounds

At most two rounds, at most 7 questions a round. Ask first what the other answers depend on
(roles before journeys, journeys before acceptance). Number each question and give your
recommended answer, so the person can reply "all as recommended":

```
Q1 - Who signs in: <the question, with the choices>
  -> Recommended: <your answer>
```

What you can look up yourself (the model, `./mxcli`, the files) you never ask. A question left
over after the second round becomes an assumption with its recommended answer.

## 3. Record the answers in the project brain

`docs/brain/` must exist first: `./mxcli brain init -p <app>.mpr` when it does not.

- **One requirement per acceptance criterion**, one sentence, anchored where it will be built --
  the anchor may name a page or microflow that does not exist yet (that reads as "not built yet"):
  ```
  ./mxcli brain capture "A customer can see only their own invoices; checked when demo_customer opens Invoices and sees no other customer's row" --slice 01-customer-sees-invoices -a @Invoicing.Invoice_Overview -p <app>.mpr
  ```
  The sentence: "<role> can <what>; checked when <what is visible>". The test for it later
  carries the same element in its `# covers:` line, which links the two -- no numbers.
- **One slice per journey** (a role and its goal): `01-customer-sees-invoices`,
  `02-clerk-sends-reminder`.
- **An assumption is only what the person did not decide** -- a question left over after the second
  round, one they left to you, every answer in `assume` mode, and anything you build differently from
  the request's own words (a sign-in where it asks to pick a user from a list) -- captured as an open question:
  `./mxcli brain capture "Assumed: one currency, EUR" --open --slice <slice> -p <app>.mpr`.
  An answer the person gave or accepted ("all as recommended" included) is a requirement, never `--open`.
- **A feature that needs a key, an account or an outside service is built, not deferred**: build it to
  work with a stand-in when the key is missing (a template text for an AI draft, a mock for a service),
  read the key from a constant left empty, and record the key as an open question for the person.
  Two B2B runs skipped a whole AI feature for want of a key; a third built it with a template and kept it.
- **Every number, limit and place the request names is its own requirement** ("one Employee, one Manager,
  two customers"; "a filter bar above the table"): what is not in the plan is lost to the next session.
- **A slice in one command:** chain its captures with `&&`, one `./mxcli brain capture ... -p <app>.mpr`
  per requirement or assumption -- not one tool call each, and not a script file of your own.

Then show the person the list -- each requirement as its sentence, grouped by slice -- and ask: "Do you
agree?" Do this even after "all as recommended": they agreed to answers, not to the requirements you
wrote from them. Only after this second yes, promote each entry, all in one command chained with `&&`:
`./mxcli brain promote <id1> -p <app>.mpr && ./mxcli brain promote <id2> -p <app>.mpr` -- their yes
is the human step. In `assume` mode promote every entry yourself, requirements and assumptions alike,
before you build: an entry left in the queue (`brain staged`) is read by no check and shown to no one.
The assumptions stay open, and the gate lists them at DONE for the person to settle.

**Never resolve an open question yourself** (`./mxcli brain resolve`): it is the person's answer. When
they give it, run `./mxcli brain resolve <id> "<their answer>"` with their words.

## 4. Then build

Each slice becomes tests and features through `test-first-delivery`, one journey at a time. **Every
requirement gets a test that checks its "checked when"**: a line `# requirement: 34a844` (the id
`brain plan` and the plan file show) right above the step that checks it, one per requirement. The gate
(REQ02) blocks a requirement no test names, and one whose step holds none of its words: name the
assertion's subject in its fail message (`fail "dates are not DD/MM/YYYY"`). `./mxcli brain plan -p <app>.mpr`
counts what is built against what was asked.

The question format comes from Matt Pocock's `grilling` skill (github.com/mattpocock/skills, MIT).
