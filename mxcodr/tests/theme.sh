#!/usr/bin/env bash
# tests/theme.sh -- the app's look: list the themes, open the preview, or switch.
#
#   bash tests/theme.sh              the themes, each as a slice of the app in its colours
#   bash tests/theme.sh preview      open the preview page (every theme, light and dark)
#   bash tests/theme.sh <n|name>     apply that theme
#
# A theme is a set of files under theme/ -- the model is never touched. Under
# `mxcli run --watch` (the gate's boot) the app shows the new look in a few seconds;
# reload the page. The bundle's own themes are created from tools/mdl-checks/themes/<name>.css.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
PORTABLE_APP_DIR="$PWD"
# shellcheck source=/dev/null
. tests/portable.sh || exit 2
HELPER=tools/mdl-checks/themes/themes.py
[ -f "$HELPER" ] || { echo "tools/mdl-checks/themes/ is missing -- re-run the installer" >&2; exit 2; }
MPR="$(ls *.mpr 2>/dev/null | head -1)"
[ -n "$MPR" ] || { echo "no .mpr here" >&2; exit 2; }

applied() {   # the theme(s) the app has now, from the partials mxcli wrote
  local file names=""
  for file in theme/web/_mxcli-*.scss; do
    [ -f "$file" ] || continue
    file="${file##*/_mxcli-}"; file="${file%.scss}"
    case "$file" in atlas-map|recipes|widgets) ;; *) names="$names $file" ;; esac
  done
  printf '%s' "${names# }"
}

case "${1:-}" in
  ""|list)
    now="$(applied || true)"
    echo "The app's look (now: ${now:-atlas, the Mendix default})"
    echo
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then "$PY" "$HELPER" list; else "$PY" "$HELPER" list --plain; fi
    echo
    echo "  bash tests/theme.sh <number|name>   switch    bash tests/theme.sh preview   see them all"
    ;;
  preview)
    page="$("$PY" "$HELPER" preview)"
    if [ "$(uname -s)" = "Darwin" ]; then open "$page"
    elif command -v cmd.exe >/dev/null 2>&1; then cmd.exe //c start "" "$(cygpath -w "$page")"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$page" >/dev/null 2>&1 &
    else echo "open this in a browser: $page"; fi
    ;;
  *)
    name="$("$PY" "$HELPER" resolve "$1")" || { echo "no theme '$1' -- bash tests/theme.sh lists them" >&2; exit 2; }
    source="$("$PY" "$HELPER" source "$name")"
    if [ "$source" = "none" ]; then
      # Mendix's own Atlas: no mxcli theme at all.
      "$MXCLI" theme remove -p "$MPR" >/dev/null 2>&1 || true
      echo "Theme: Mendix Atlas. With the app running under --watch, reload the page in a few seconds."
      exit 0
    fi
    if [ "$source" != "builtin" ] && [ ! -d "theme/mxcli-themes/$name" ]; then
      "$MXCLI" theme create "$name" -p "$MPR" --from "$source" --base signal >/dev/null \
        || { echo "mxcli theme create $name failed" >&2; exit 1; }
      # The frame (top bar, active menu item, outline buttons) goes into the scaffold's own partial.
      skin="$("$PY" "$HELPER" skin "$name")" \
        && cat "$skin" >> "theme/mxcli-themes/$name/files/theme/web/_mxcli-$name.scss"
    fi
    "$MXCLI" theme apply "$name" -p "$MPR" >/dev/null || { echo "mxcli theme apply $name failed" >&2; exit 1; }
    echo "Theme: $name. With the app running under --watch, reload the page in a few seconds."
    ;;
esac
