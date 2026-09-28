#!/usr/bin/env bash
# Codex UserPromptSubmit hook: prints the project rules, injected as context before every prompt. Exit 0.
# Same template as remind-skills.sh; Codex names a skill `$name` and has no precheck hook, so it runs
# tests/precheck.sh itself.
# shellcheck source=remind-skills-lib.sh
. "$(dirname "$0")/remind-skills-lib.sh"
mdl_reminder '.claude/rules/mdl-skills.md' \
  'load `$test-first-delivery`' \
  'then `bash tests/precheck.sh <script>.mdl` (mx check on a copy: what a build or a half-applied script would hit)'
