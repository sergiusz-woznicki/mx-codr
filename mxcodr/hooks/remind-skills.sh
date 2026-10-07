#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook: prints the project rules, added as context to every prompt. Exit 0.
# The text is tools/mdl-checks/reminder.txt, shared with the Codex and Cursor hooks and the OpenCode plugin.
# shellcheck source=remind-skills-lib.sh
. "$(dirname "$0")/remind-skills-lib.sh"
mdl_mark_session
mdl_reminder '.claude/rules/mdl-skills.md' \
  'invoke the Skill tool with `test-first-delivery`' \
  '(a hook runs `tests/precheck.sh` for you -- mx check on a copy; do not call it by hand)'
