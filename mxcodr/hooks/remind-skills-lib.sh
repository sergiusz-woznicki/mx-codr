#!/usr/bin/env bash
# hooks/remind-skills-lib.sh -- the per-prompt reminder, from one template for every host. Sourced
# by remind-skills.sh (Claude Code), remind-skills-codex.sh and remind-skills-cursor.sh, and read by
# the OpenCode plugin; never run on its own. Five copies of the text once drifted apart.
# The template is checks/reminder.txt in the bundle, tools/mdl-checks/reminder.txt once installed.
#
# mdl_reminder <rules file> <how to load test-first-delivery> <the precheck clause>

mdl_reminder_template() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in "$here/../reminder.txt" "$here/../checks/reminder.txt"; do
    [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

mdl_reminder() {
  local template
  if template="$(mdl_reminder_template)"; then
    # Literal substitution: the values hold backticks and slashes, so no sed.
    local text
    text="$(cat "$template")"
    text="${text//\{\{RULES_FILE\}\}/$1}"
    text="${text//\{\{LOAD_SKILL\}\}/$2}"
    text="${text//\{\{PRECHECK\}\}/$3}"
    printf '%s\n' "$text"
  else
    printf 'Project rules: read `%s` first; a feature starts with tests/verify-<feature>.test.sh and `bash tests/gate.sh --only <feature> --boot-if-needed`; done = `bash tests/gate.sh` ends in `DONE`.\n' "$1"
  fi
}
