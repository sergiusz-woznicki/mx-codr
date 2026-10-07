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

# mdl_mark_session -- the agent session's id (session_id, conversation_id or sessionId in the hook's
# JSON on stdin) into .mxcli/session.id, for tests/db-snapshot.sh: one snapshot per session, rolled
# back after its first DONE. Writes only when it changed; nothing outside a Mendix project.
mdl_mark_session() {
  local input id root
  input="$(cat 2>/dev/null)"
  id="$(printf '%s' "$input" | grep -oE '"(session_id|conversation_id|sessionId)"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._-]+"' \
    | head -1 | sed -E 's/.*"([A-Za-z0-9._-]+)"$/\1/')"
  [ -n "$id" ] || return 0
  root="${CLAUDE_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-$PWD}}"
  ls "$root"/*.mpr >/dev/null 2>&1 || return 0
  [ "$(cat "$root/.mxcli/session.id" 2>/dev/null)" = "$id" ] && return 0
  mkdir -p "$root/.mxcli" 2>/dev/null && printf '%s' "$id" > "$root/.mxcli/session.id" 2>/dev/null
  return 0
}
