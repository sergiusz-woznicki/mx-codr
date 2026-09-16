#!/usr/bin/env bash
# Cursor sessionStart hook (Cursor has no per-prompt context injection): prints {"additional_context": "<rules>"}. Exit 0.
# .cursor/rules/mdl-skills.mdc keeps the rules attached to later requests.
set -uo pipefail

# Prints the first Python that actually runs (Windows may have only a Store stub); inlined so the hook is self-contained.
mdl_find_python() {
  local candidate
  for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  # The python.org installer does not add Python to PATH by default.
  local local_app="${LOCALAPPDATA:-}"
  local_app="${local_app//\\//}"
  for candidate in \
      "$local_app/Programs/Python"/Python3*/python.exe \
      "$local_app/Programs/Python/Launcher/py.exe" \
      "/c/Program Files"/Python3*/python.exe \
      "/c/Program Files (x86)"/Python3*/python.exe; do
    [ -x "$candidate" ] || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
PY="$(mdl_find_python || true)"
PY="${PY:-python3}"

cat <<'MSG' | "$PY" -c 'import json,sys; print(json.dumps({"additional_context": sys.stdin.read().strip()}))'
Project rule: start by running `bash tests/orient.sh` (one call, ~0.3s: structure, security, navigation, tests and their covers, coverage, lint, app state) instead of exploring by hand. Before building or changing any feature, read `.cursor/rules/mdl-skills.mdc` and the skill it names -- `test-first-delivery` (failing test first). Before creating a module or placing documents: `module-structure`. Before writing a page: `spacing-and-layout` -- two inline widgets side by side need `DesignProperties: ['Spacing': ['margin-right': 'S']]`, never CSS. Before writing a microflow: `naming-and-captions` -- every decision AND every action (retrieve, create, change, commit, delete, call, show page, set) needs a business `@caption`; the gate's naming check fails on a missing one or on the Mendix default. If the Skill tool does not list them -- it lists what existed when the session STARTED, so skills installed since are invisible to it -- read exactly those four files instead, `.claude/skills/<name>/SKILL.md`, and nothing else up front. Do not sweep the other SKILL.md files before starting: entity, page, microflow and navigation syntax is a lookup at the moment you need it (`./mxcli syntax <topic>`, then `./mxcli check <script>.mdl -p <app>.mpr --references` before every exec). One session that read twelve of them first spent 6.5 minutes and 36 commands before it ran anything. The skills themselves are in `.ai-context/skills/<name>/SKILL.md`. Run the new test and watch it FAIL before implementing: `bash tests/gate.sh --only <feature> --boot-if-needed` (it starts the app if nothing is running). While you iterate run that same ONE script; when it goes red the gate prints the facts (rows, sessions, access rules) under the failure by itself. A feature is not done until `bash tests/gate.sh` (suite + mx check + lint + coverage + naming + layout, one call) ends in `DONE`.
MSG
