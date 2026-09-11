# The Mendix delivery harness

A drop-in bundle that makes an AI coding agent follow five project rules while it
builds a Mendix app, and gives one command that says whether the work is done.

The rules are prose the agent reads. The enforcement is lint rules, checkers and a
gate that fails. Neither half is useful alone: the prose without the gate is advice
an agent drifts from by the third feature, and the gate without the prose only ever
says no.

`dist/` is the whole bundle. Everything below is about installing and using it.

## You run the installer. That is the only command you have to run.

Nothing in this harness is a tool you operate. There is no Python script to invoke,
no checker to remember the arguments of, no order to run things in. After
`install.sh`, every piece is found and used by the agent on its own:

| What | How the agent finds it |
|---|---|
| The five rules, in prose | `SKILL.md` files in the three directories each host looks in |
| The always-loaded reminder | `.claude/rules/` and `.cursor/rules/`, loaded on every turn |
| `MOD001`, `REU001` | `mxcli lint` discovers `.claude/lint-rules/*.star` by itself |
| `check_mdl.py`, `check_test_coverage.py` | the skills that need them name the exact command; the gate runs them too |
| The gate | host hooks fire it, and the `test-first-delivery` skill tells the agent to |

The Python checkers exist because two of the rules cannot be expressed as lint
rules — activity captions are not in the model catalog, and test coverage means
reading `tests/` off disk. They are an implementation detail of those two rules,
installed at `tools/mdl-checks/` so every host can cite one path. The agent calls
them. **You never have to.**

The same is true of `tests/gate.sh`. The hooks run it, and the skills tell the agent
to run it before claiming anything is finished. You can run it yourself when you
want to see where a project stands — that is a convenience, not a step.

So the whole of your involvement is:

```bash
bash install.sh --with-deps
```

and then working with your agent as usual.

## What it enforces

| Rule | What it asks for |
|---|---|
| `test-first-delivery` | a failing test before the feature, and a test naming every page and `ACT_` microflow |
| `module-structure` | documents in process-named folders, `ACT_`/`SUB_` split, microflows under 15 activities |
| `naming-and-captions` | PascalCase, `ENUM_`/`SNIPPET_` prefixes, `_NewEdit`/`_View`/`_Overview` pages, a business caption on every activity |
| `reuse-and-snippets` | a snippet used on more than one page, a `SUB_` microflow with more than one caller |
| `organize-project` | nothing orphaned, nothing left at module root |

## Requirements

| | Why |
|---|---|
| **mxcli** | everything runs through it |
| **Mendix Studio Pro** or a cached mxbuild | `mx check` validates the model |
| **PostgreSQL** | the app's database, and a separate `<project>_test` one |
| **bash** | the harness is shell scripts — Git Bash on Windows |
| **Python 3** | for the two checkers the agent calls; you never invoke it |
| **Node + playwright-cli** | the browser tests |
| **A JDK** | matching the Mendix version; Studio Pro installs one |
| **Docker** | installed as a prerequisite |

`--with-deps` installs the ones that can be installed unattended. It never installs
a JDK — that wants a licence click.

## Install

Copy `dist/` into your Mendix project, `cd` into it, and run:

```bash
bash install.sh --with-deps
```

Run from inside the bundle it installs into the project the bundle sits in, which
is what you mean when you have just copied `dist/` into your app.

```
bash install.sh [path-to-project] [--no-app] [--with-deps]

  path-to-project  where to install (default: the current directory, or the
                   parent project when run from inside the bundle)
  --no-app         never create a Mendix app; require one to be there already
  --with-deps      install missing prerequisites with this machine's package
                   manager. Without it they are only reported.
```

With no `.mpr` in the target and `--with-deps`, it creates a Mendix app for you.

### Windows

There is no bash on Windows until something installs it, so there is a second
entry point for that one job:

```powershell
powershell -ExecutionPolicy Bypass -File bootstrap.ps1
```

It installs Git for Windows, Python and Node with winget, then hands over to
`bash install.sh --with-deps`.

**Run it from an elevated terminal.** winget's Docker Desktop install asks for
administrator rights, and unelevated it fails with `exit code: 4294967291` and is
reported as missing.

If you already have Git Bash, skip `bootstrap.ps1` and use `install.sh` directly.

### What lands in the project, and who reads it

```
.claude/skills/<name>/       Claude Code
.agents/skills/<name>/       Codex, and other tools on the open SKILL.md standard
.ai-context/skills/<name>/   mxcli, Cursor, OpenCode, Windsurf, Aider
.claude/rules/               the always-loaded rule (Cursor's copy in .cursor/rules/)
.claude/lint-rules/          found by `mxcli lint` with nothing to register
tools/mdl-checks/            the Python checkers the skills cite
tests/                       the harness scripts, plus tests/harness.env
.claude/settings.local.json  the hooks (Cursor, Codex and OpenCode get their own)
```

Three copies of the same skills, because each tool looks somewhere different. All
of it is discovered — nothing here needs registering, importing or configuring.

The five harness scripts are replaced on every install: a fix in `gate.sh` that
never reaches an installed project is not a fix. Your own `verify-*.test.sh` and
`credentials.env` are never overwritten.

## The gate

One command, five checks, run concurrently — the browser suite, `mx check`, `mxcli
lint`, test coverage and naming/captions. Every step runs even when another fails,
so one call reports the whole picture. Exit 0 only when all five pass.

```
== gate
   tests: Total: 12  Passed: 12  Failed: 0  Time: 2m14s
   mx check: 0 errors
   lint: 59 issues: 0 errors, 24 warnings, 35 info
   coverage InvoiceDesk: PASS  14/14 elements covered by 12 test script(s)
   naming: PASS  0 failure(s) over 246 lines
   DONE — every check passed
```

The agent runs this. The installed hooks run it too, and refuse to let Codex or
Cursor finish a turn while it is red. When you want to look yourself:

```bash
bash tests/gate.sh                    # the done gate
bash tests/gate.sh --boot-if-needed   # boot the app first if nothing answers
bash tests/gate.sh --only <feature>   # one test, warm browser, red loop
bash tests/orient.sh                  # what is in this project
bash tests/diagnose.sh                # why is the app not answering
```

## Configuration

`tests/harness.env` is written by the installer and read by every harness script.
The environment still wins, so any of it can be overridden for one run.

| Key | What it is |
|---|---|
| `MDL_MXBUILD_PATH` | the Studio Pro or cached mxbuild `mx check` runs |
| `MDL_DB_HOST` / `_NAME` / `_USER` / `_PASSWORD` | the database |
| `JAVA_HOME` | a JDK on a path with **no spaces** (see below) |
| `MDL_BOOT_COMMAND` | how the gate boots the app when nothing answers |

## Windows: what the installer repairs, and what it cannot

Four things stand between a Windows machine and a running Mendix app, and none of
them reports itself usefully. The installer fixes three, without being asked.

| | Symptom if unfixed |
|---|---|
| A JDK on a path with spaces | mxbuild splits its own command line, so `C:\Program Files (Arm)\zulu21` arrives as four unrecognised arguments and it exits printing usage |
| No Gradle in the mxbuild cache | `No supported Gradle installation found`, raised after mxbuild is already answering, so it reads as a model problem |
| ARM Studio Pro ships `win-arm64` tools only | mxbuild launches `win-x64` and dies with `Win32Exception (2)` before it listens |

Junctions, so nothing is copied and no administrator rights are needed.

**The fourth cannot be fixed from outside mxcli.** Its liveness probe is
`os.Process.Signal(0)`, and Windows rejects every signal except `Kill` — so a
perfectly healthy mxbuild and a perfectly healthy runtime both read as *"exited
during startup"* on the first poll. This is not an ARM quirk; no Windows machine
can boot an app with `mxcli run --local`.

The harness works around it for booting: the installer writes
`MDL_BOOT_COMMAND="bash tests/run-app.sh"`, which drives mxbuild and the standalone
runtime over the M2EE admin API instead. `gate.sh --boot-if-needed` then works.

There is no equivalent for **`mxcli test --local`**, which boots the app itself.
Microflow tests need a patched mxcli on Windows until the fix is upstream.

### Two more Windows notes

**Ports.** Studio Pro running an app holds 8080 and 8090. The harness defaults to
8081, which still collides on the admin port. Pass `APP_PORT` / `ADMIN_PORT` if you
are running both at once.

**Screenshots** need `playwright` (the npm package), not `playwright-cli` (the
session tool `mxcli playwright` drives). Having only the second is what makes
Playwright look installed while `mxcli run --local --screenshot` does nothing. Its
Chromium is a separate download, pinned per package, so one tool's browser does not
satisfy the other.

## If a test run fails partway, check `AfterStartupMicroflow`

`mxcli test` points the project's after-startup microflow at its own injected
`MxTest.RegisterEndpoint` while tests run. A run that dies before cleanup leaves it
there, overwriting whatever the app had — with no record of the old value. The next
run then fails somewhere else entirely, because it reads the leftover as your
setting.

```bash
./mxcli -p <app>.mpr -c 'SHOW SETTINGS'     # look at AfterStartup
./mxcli -p <app>.mpr -c "ALTER SETTINGS MODEL AfterStartupMicroflow = 'Module.Microflow'"
```

mxcli does warn that the project was left modified. It does not say what the value
was, so note it before running tests against a project you care about.

## Rebuilding the bundle

`dist/` is a copy of files that live in the harness repo — `dist/README.md` has the
table of which file comes from where. Edit it there, not here.
