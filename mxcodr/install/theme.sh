# install/theme.sh -- part of install.sh, which sources the parts in order; never run it on its own.
# The app's look: eight themes to choose from when the installer creates the app. Functions only.
# The list and the preview page come from checks/themes/ (catalog.json, built from the themes'
# real tokens by tests/skills/build-themes.py in the mx-codr repo).

# open_in_browser <file> -- best effort, silent: macOS open, Windows start, Linux xdg-open.
open_in_browser() {
  [ -n "${MDL_NO_BROWSER:-}" ] && return 1
  if command -v open >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then open "$1" >/dev/null 2>&1
  elif command -v cmd.exe >/dev/null 2>&1; then cmd.exe //c start "" "$(cygpath -w "$1" 2>/dev/null || echo "$1")" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 &
  else return 1; fi
}

# choose_theme -- sets THEME for a new app. MDL_THEME picks it without asking; with no terminal,
# or MDL_ASSUME_YES, the first theme (atlas, Mendix's own look) is taken. Asked together with the other questions,
# before the minutes of unattended work.
choose_theme() {
  local helper="$SRC/checks/themes/themes.cjs" reply preview opened=0
  # The default even when nothing can be asked: Mendix's own Atlas, the app as mxcli new makes it.
  THEME="atlas"
  [ -n "${NODE:-}" ] || NODE="$(mdl_find_node 2>/dev/null || true)"
  [ -f "$helper" ] && [ -n "${NODE:-}" ] || return 0
  if [ -n "${MDL_THEME:-}" ]; then
    THEME="$("$NODE" "$helper" resolve "$MDL_THEME" 2>/dev/null)" \
      || ui_fail "MDL_THEME=$MDL_THEME is not one of the themes:" "$("$NODE" "$helper" list --plain)"
    return 0
  fi
  THEME="$("$NODE" "$helper" resolve "" 2>/dev/null)"
  if [ ! -t 0 ] || [ -n "${MDL_ASSUME_YES:-}" ]; then return 0; fi
  preview="$("$NODE" "$helper" preview)"
  open_in_browser "$preview" && opened=1
  printf '  How should the app look?'
  if [ "$opened" = 1 ]; then
    printf '  %s(the preview opened in your browser)%s\n\n' "$C_GREY" "$C_RESET"
  else
    printf '\n  %sPreview: %s%s\n\n' "$C_GREY" "$preview" "$C_RESET"
  fi
  if [ "$UI_TTY" = 1 ]; then "$NODE" "$helper" list; else "$NODE" "$helper" list --plain; fi
  printf '\n    %smenu · top bar · page · selected row · button. Change it later: bash tests/theme.sh%s\n' "$C_GREY" "$C_RESET"
  while :; do
    printf '\n  Theme [1]: '
    read -r reply
    THEME="$("$NODE" "$helper" resolve "$reply" 2>/dev/null)" && break
    printf '  %sType a number from the list, or a theme name.%s\n' "$C_YELLOW" "$C_RESET"
  done
  printf '\n'
}

# apply_theme <app-dir> <mxcli> <name> -- a built-in theme by name; the bundle's own are created
# from their token file on the signal base first. Only theme/ files change, never the model.
apply_theme() {
  local app="$1" mxcli="$2" name="$3" source mpr skin
  [ -n "$name" ] || return 0
  mpr="$(cd "$app" && ls *.mpr 2>/dev/null | head -1)"
  [ -n "$mpr" ] || return 1
  source="$("$NODE" "$SRC/checks/themes/themes.cjs" source "$name" 2>/dev/null)" || return 1
  # The mx-codr mark in this theme's colours replaces Mendix's icons and logos (theme/web/ only).
  "$NODE" "$SRC/checks/themes/themes.cjs" logo "$name" "$app" >/dev/null 2>&1 || true
  # Atlas is no theme at all: take away any mxcli theme the app carries.
  if [ "$source" = "none" ]; then
    ( cd "$app" && "$mxcli" theme remove -p "$mpr" ) >/dev/null 2>&1 || true
    return 0
  fi
  if [ "$source" != "builtin" ] && [ ! -d "$app/theme/mxcli-themes/$name" ]; then
    ( cd "$app" && "$mxcli" theme create "$name" -p "$mpr" --from "$source" --base signal ) >/dev/null 2>&1 || return 1
    # The frame (top bar, active menu item, outline buttons) goes into the scaffold's own partial.
    skin="$("$NODE" "$SRC/checks/themes/themes.cjs" skin "$name" 2>/dev/null)" \
      && cat "$skin" >> "$app/theme/mxcli-themes/$name/files/theme/web/_mxcli-$name.scss"
  fi
  ( cd "$app" && "$mxcli" theme apply "$name" -p "$mpr" --variant light ) >/dev/null 2>&1
}
