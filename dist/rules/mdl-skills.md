# Project skills that are always in force

Five skills are installed in `.claude/skills/` that are **not** in the skill table
mxcli writes into `CLAUDE.md`. That table lists only mxcli's own skills; these are
this project's, and they apply on top of it. Load them with the Skill tool, before
the work, not after:

| When | Skill |
|---|---|
| Adding, changing or fixing **any** feature — a page, a button, a microflow, an action | `test-first-delivery` — the failing test comes first, and nothing is done until the whole suite is green |
| Creating a module, adding the first documents to one, or deciding which folder a document goes in | `module-structure` |
| Writing or changing any microflow, nanoflow or rule | `naming-and-captions` — a business `@caption` on every decision **and** every action (retrieve, create, change, commit, delete, call, show page, set), never the Mendix default |
| A second page, snippet or microflow that resembles an existing one | `reuse-and-snippets` |
| Moving documents between folders or modules | `organize-project` |

Facts about this app come from one call, not from exploring by hand -- each of these
runs its lookups in parallel and answers in well under a second:

```bash
bash tests/orient.sh                            # structure, security, navigation, tests + covers, coverage, lint, app state
bash tests/diagnose.sh <Entity> <user>          # row counts, sessions, access rules, associations, runtime errors
```

While you iterate, keep the app up in another terminal and run one script at a
time -- the suite is for the end, not the loop:

```bash
bash tests/gate.sh --boot-if-needed          # starts the app the way this project starts it
bash tests/gate.sh --only <feature>          # one script against the running app
```

`--boot-if-needed` is the portable way in. `./mxcli run --local --watch` gives a ~1s
hot reload where it works, but it deadlocks on some machines, and where the runtime
serves a built deployment there is no hot reload at all -- a model change is invisible
until a rebuild. `tests/harness.env` records how this project boots
(`MDL_BOOT_COMMAND`), so the gate is the one command that is right everywhere.

Never debug by rerunning the whole suite. A test that passes alone and fails in the
suite is a test-isolation bug (sign-in identity, or data left behind) and is fixed in
`tests/lib.sh`.

"Done" for a feature is one command, reported as command output — it runs the suite,
`mx check`, lint and the coverage checker, and ends in `DONE` or `NOT DONE`:

```bash
bash tests/gate.sh
```

`mxcli init` regenerates `CLAUDE.md`, `AGENTS.md` and `.claude/settings.json`; it
does not touch this file, `.claude/skills/` or `.claude/settings.local.json`, which
is why the project's own rules live here.

On Windows the harness runs under Git Bash or WSL2 and the binary is
`./mxcli.exe`; everything else here is unchanged.
