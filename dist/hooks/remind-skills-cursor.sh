#!/usr/bin/env bash
# Cursor sessionStart hook. Cursor has no per-prompt injection point --
# beforeSubmitPrompt can only allow or block a prompt, it cannot add context --
# so the rules are stated once, at the start of the session, through
# additional_context. The .cursor/rules/mdl-skills.mdc rule (alwaysApply) is what
# keeps them attached to every later request.
#
# Output contract: JSON on stdout, exit 0.
set -uo pipefail

# Windows (Git Bash) has no `python3`, and a `python3.exe` stub that opens the
# Microsoft Store instead of running anything is common, so each candidate is asked
# to run before it is believed. Inlined rather than sourced: a hook has to work with
# nothing else on disk but itself.
mdl_find_python() {
  local candidate
  for candidate in python3 python py; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import json,sys' >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  # The python.org installer leaves "Add python.exe to PATH" unticked by default
  # and winget accepts that default, so a Windows box can hold a working Python
  # that no shell can see. Observed on a clean Windows 11 VM.
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
Project rule: start by running `bash tests/orient.sh` (one call, ~0.3s: structure, security, navigation, tests and their covers, coverage, lint, app state) instead of exploring by hand. Before building or changing any feature, read `.cursor/rules/mdl-skills.mdc` and the skill it names -- `test-first-delivery` (failing test first). Before creating a module or placing documents: `module-structure`. Before writing a microflow: `naming-and-captions` -- every decision AND every action (retrieve, create, change, commit, delete, call, show page, set) needs a business `@caption`; the gate's naming check fails on a missing one or on the Mendix default. The skills themselves are in `.ai-context/skills/<name>/SKILL.md`. Run the new test and watch it FAIL before implementing: `bash tests/gate.sh --only <feature> --boot-if-needed` (it starts the app if nothing is running). While you iterate run that same ONE script; when it goes red the gate prints the facts (rows, sessions, access rules) under the failure by itself. A feature is not done until `bash tests/gate.sh` (suite + mx check + lint + coverage, one call) ends in `DONE`.
MSG
