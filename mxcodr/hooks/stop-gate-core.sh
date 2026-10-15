#!/usr/bin/env bash
# hooks/stop-gate-core.sh -- what the Codex and Cursor stop hooks share: run the gate at the end of a
# turn that changed the model, and say what is left. Sourced by stop-gate-codex.sh and
# stop-gate-cursor.sh, never run on its own; each of them finds its marker and answers its host its
# own way.

# NODE and HOOK_TOOL, when the host hook has not set them already.
[ -n "${HOOK_TOOL:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/hook-env.sh"

# stop_gate_run <marker> -- in the project directory, after the host's own checks.
#   0  nothing to say: the gate is DONE (the marker is removed), the person is logging in to the
#      Marketplace, or film.sh --all is recording in the browser the gate needs
#   1  only the person can clear what is left: STOP_GATE_TEXT says what (the marker is removed, so
#      the agent is told once and not sent back again)
#   2  the gate failed: STOP_GATE_TEXT is the end of its output
STOP_GATE_TEXT=""
stop_gate_run() {
  local marker="$1" output status film_pid owners
  # Waiting for the person's Marketplace login: let the turn end so they can answer.
  if [ -f tests/marketplace-login.sh ]; then
    bash tests/marketplace-login.sh before "bash tests/gate.sh" >/dev/null 2>&1
    [ $? -eq 3 ] && return 0
  fi
  # film.sh --all records in the background in the browser the gate needs: end the turn, gate later.
  film_pid="$(cat .mxcli/films/.all.pid 2>/dev/null)"
  case "$film_pid" in ''|*[!0-9]*) ;; *) kill -0 "$film_pid" 2>/dev/null && return 0 ;; esac
  output="$(bash tests/gate.sh 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && grep -Fq 'DONE — every check passed' <<< "$output"; then
    rm -f "$marker"
    return 0
  fi
  owners="$("$NODE" "$HOOK_TOOL" person-only . <<< "$output" 2>/dev/null)"
  if [ -n "$owners" ]; then
    rm -f "$marker"
    STOP_GATE_TEXT="$owners"
    return 1
  fi
  # Gate output contains project text: the hosts fence and label it as data; capped here.
  STOP_GATE_TEXT="$(printf '%s' "$output" | tail -c 6000)"
  return 2
}
