#!/usr/bin/env bash
# tests/mdl-applied.sh -- what each script wrote the last time it ran, for STALE01 (tests/precheck.sh).
# Sourced; defines functions only. The after-exec hook calls mdl_applied_record after an exec that
# applied; precheck.sh calls mdl_applied_reference before the next one.
#   .mxcli/applied/<script path, / as %>   the script as it was when it last applied
# Only scripts inside the project are kept (a path with .. or from / is someone else's).

MDL_APPLIED_DIR=".mxcli/applied"

mdl_applied_key() {   # the file name a script's copy is kept under, or false
  case "$1" in /*|*..*|'') return 1 ;; esac
  printf '%s' "${1#./}" | tr '/\\' '%%'
}

mdl_applied_record() {   # mdl_applied_record <script>... -- after an exec that applied
  local script key
  for script in "$@"; do
    [ -f "$script" ] || continue
    key="$(mdl_applied_key "$script")" || continue
    mkdir -p "$MDL_APPLIED_DIR" 2>/dev/null || return 0
    cp "$script" "$MDL_APPLIED_DIR/$key" 2>/dev/null
  done
  return 0
}

# mdl_applied_reference <script> -- prints the path of what the script last wrote: its kept copy,
# else the version in git's HEAD (written to <copy>.git, removed by the caller); false when neither.
mdl_applied_reference() {
  local key copy
  key="$(mdl_applied_key "$1")" || return 1
  copy="$MDL_APPLIED_DIR/$key"
  if [ -f "$copy" ]; then printf '%s\n' "$copy"; return 0; fi
  command -v git >/dev/null 2>&1 || return 1
  git ls-files --error-unmatch "${1#./}" >/dev/null 2>&1 || return 1
  mkdir -p "$MDL_APPLIED_DIR" 2>/dev/null || return 1
  git show "HEAD:${1#./}" > "$copy.git" 2>/dev/null || { rm -f "$copy.git"; return 1; }
  printf '%s\n' "$copy.git"
}
