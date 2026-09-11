#!/usr/bin/env bash
# Codex UserPromptSubmit hook. Plain stdout is injected as developer context
# before every prompt. Keep this separate from Claude's reminder so each host
# receives the skill invocation vocabulary it understands.
cat <<'MSG'
Project rule: start by running `bash tests/orient.sh` (one call, ~0.3s: structure, security, navigation, tests and their covers, coverage, lint, app state) instead of exploring by hand. Before building or changing any feature, load `$test-first-delivery` (failing test first). Before creating a module or placing documents, load `$module-structure`. Before writing a microflow, load `$naming-and-captions` -- every decision AND every action (retrieve, create, change, commit, delete, call, show page, set) needs a business `@caption`; the gate's naming check fails on a missing one or on the Mendix default. Run the new test and watch it FAIL before implementing: `bash tests/gate.sh --only <feature> --boot-if-needed` (it starts the app if nothing is running). While you iterate run that same ONE script; when it goes red the gate prints the facts (rows, sessions, access rules) under the failure by itself. A feature is not done until `bash tests/gate.sh` (suite + mx check + lint + coverage, one call) ends in `DONE`.
MSG
