#!/usr/bin/env bash
# tests/film.sh -- a video of a browser test's run, with the test's name on it.
#
#   bash tests/film.sh --list                 # every test: what it walks through, who signs in
#   bash tests/film.sh mastermind             # tests/verify-mastermind.test.sh -> .mxcli/films/mastermind.webm
#   bash tests/film.sh orders toasts          # several, one film each
#   bash tests/film.sh --all                  # every test with a browser, plus .mxcli/films/all.mp4
#
# The test runs unchanged, at its own speed, in the browser the tests share; playwright-cli records
# that browser and opens the film with a card naming the test; a mouse pointer moves to each click.
# With ffmpeg there is an .mp4 next to each .webm. A failing test keeps its film. Nothing is filmed
# while a gate or a test holds the browser, and the app has to be up (bash tests/gate.sh
# --boot-if-needed).
# Inputs: APP_PORT / BASE_URL as for the tests; TEST_USER as each test sets it.

set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1
APP_DIR="$(pwd)"
# portable.sh reads tests/harness.env (APP_PORT) as data; app.sh knows whose app answers a port.
# shellcheck source=portable.sh
. tests/portable.sh
# shellcheck source=gate/app.sh
. tests/gate/app.sh
FILMS=.mxcli/films

# name <script> -- verify-mastermind.test.sh -> mastermind.
name_of() { local base; base="$(basename "$1" .test.sh)"; printf '%s' "${base#verify-}"; }
# True when the test opens a browser at all (an API or OQL test has nothing to film).
films_something() { grep -q "^[^#]*scenario '" "$1"; }

list_tests() {
  local script name user covers
  for script in tests/verify-*.test.sh; do
    [ -f "$script" ] || continue
    name="$(name_of "$script")"
    user="$(sed -n 's/^export TEST_USER=//p' "$script" | head -1)"
    covers="$(sed -n 's/^# covers: *//p' "$script" | head -1)"
    echo "== $name${user:+  (signed in as $user)}"
    films_something "$script" || echo "   no browser in this test: nothing to film"
    [ -n "$covers" ] && echo "   covers: $covers"
    # The header's prose: the comment lines after `# covers:`, up to the first line of code.
    awk 'NR > 2 && /^#/ { sub(/^# ?/, "   "); if ($0 != "   ") print; next } NR > 2 { exit }' "$script"
  done
}

# The width and height the shared browser's page has now, as "WxH"; 1280x800 when it cannot tell.
viewport() {
  local out
  out="$(playwright-cli run-code "async page => { const v = page.viewportSize(); return v ? v.width + 'x' + v.height : ''; }" 2>/dev/null)"
  out="$(printf '%s\n' "$out" | grep -oE '[0-9]{3,4}x[0-9]{3,4}' | tail -1)"
  printf '%s' "${out:-1280x800}"
}

# A mouse pointer for the film: headless Chromium draws none. An arrow in the page follows the
# mouse the test moves (every click moves it). playwright-cli's own pointer (video-show-actions)
# comes only with a label naming each action -- `Fill "<the test password>"` among them -- so it
# is not used. The script stays in the browser until it closes; film.sh closes it at the end.
cursor_script() {
  cat <<'JS'
async page => {
  const draw = () => {
    const add = () => {
      if (document.getElementById('mxcodr-film-cursor')) return;
      const c = document.createElement('div');
      c.id = 'mxcodr-film-cursor';
      c.innerHTML = '<svg width="26" height="36" viewBox="0 0 22 30"><path d="M1 1 L1 24 L7 18 L11 28 L15 26 L11 17 L19 17 Z" fill="#111" stroke="#fff" stroke-width="1.5"/></svg>';
      c.style.cssText = 'position:fixed;left:-40px;top:-40px;pointer-events:none;z-index:2147483647;' +
        'transition:left 120ms linear,top 120ms linear,transform 80ms';
      document.documentElement.appendChild(c);
      const move = e => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; };
      addEventListener('mousemove', move, true);
      addEventListener('mousedown', e => { move(e); c.style.transform = 'scale(0.8)'; }, true);
      addEventListener('mouseup', () => { c.style.transform = ''; }, true);
    };
    if (document.documentElement) add(); else addEventListener('DOMContentLoaded', add);
  };
  await page.context().addInitScript(`(${draw})()`);
  await page.evaluate(`(${draw})()`);
}
JS
}

# film <name> -- record one test; prints the film and the verdict, returns the test's status.
film() {
  local name="$1" script="tests/verify-$1.test.sh" status out size
  size="$(viewport)"
  mkdir -p "$FILMS"
  rm -f "$FILMS/$name.webm" "$FILMS/$name.mp4"
  playwright-cli video-start "$FILMS/$name.webm" --size "$size" >/dev/null 2>&1 \
    || { echo "film: playwright-cli could not start recording" >&2; return 2; }
  playwright-cli video-chapter "$name" --duration 2000 >/dev/null 2>&1
  sleep 2
  out="$(BASE_URL="$BASE_URL" bash "$script" 2>&1)"; status=$?
  sleep 1
  playwright-cli video-stop >/dev/null 2>&1
  if [ ! -s "$FILMS/$name.webm" ]; then
    echo "film: $name ran, but no film was written" >&2
    return 2
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    # One frame size for every film, so --all can join them.
    ffmpeg -v error -y -i "$FILMS/$name.webm" -c:v libx264 -pix_fmt yuv420p -movflags +faststart -r 25 \
      -vf 'scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:white' "$FILMS/$name.mp4" \
      || rm -f "$FILMS/$name.mp4"
  fi
  if [ "$status" = "0" ]; then
    echo "PASS  $name -> $FILMS/$name.$( [ -s "$FILMS/$name.mp4" ] && echo mp4 || echo webm)"
  else
    echo "FAIL  $name -> $FILMS/$name.$( [ -s "$FILMS/$name.mp4" ] && echo mp4 || echo webm) (the film shows where it stopped)"
    printf '%s\n' "$out" | grep -E 'FAIL|Error' | head -3 | sed 's/^/      /'
  fi
  return "$status"
}

case "${1:-}" in
  ''|-h|--help)
    sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  --list)
    list_tests
    exit 0 ;;
esac

# Which tests: names given, or every one with a browser.
names=()
if [ "$1" = "--all" ]; then
  for script in tests/verify-*.test.sh; do
    [ -f "$script" ] || continue
    if films_something "$script"; then names+=("$(name_of "$script")")
    else echo "skip  $(name_of "$script") (no browser in this test)"; fi
  done
else
  for name in "$@"; do
    name="${name#verify-}"; name="${name%.test.sh}"
    if [ ! -f "tests/verify-$name.test.sh" ]; then
      echo "film: no test named '$name'. The tests here: $(for s in tests/verify-*.test.sh; do printf '%s ' "$(name_of "$s")"; done)" >&2
      exit 2
    fi
    films_something "tests/verify-$name.test.sh" || { echo "film: $name opens no browser -- nothing to film" >&2; exit 2; }
    names+=("$name")
  done
fi
[ "${#names[@]}" -gt 0 ] || { echo "film: no test with a browser to film" >&2; exit 2; }

# One browser for every test and the gate: never record over a run that is using it.
if pgrep -f 'tests/gate\.sh|mxcli playwright verify|verify-[A-Za-z0-9_-]*\.test\.sh' 2>/dev/null | grep -qvx "$$"; then
  echo "film: a gate or a test is running and holds the shared browser -- film when it is done" >&2
  exit 2
fi
APP_PORT="${APP_PORT:-8081}"
BASE_URL="${BASE_URL:-http://localhost:$APP_PORT}"
if ! answers "$BASE_URL"; then
  echo "film: no app answers at $BASE_URL -- start it first: bash tests/gate.sh --boot-if-needed" >&2
  exit 2
fi
port="${BASE_URL##*:}"; port="${port%%/*}"
other="$(foreign_runtime "$port")"
if [ -n "$other" ]; then
  echo "film: $BASE_URL is another project's app ($other) -- stop it, or set APP_PORT in tests/harness.env" >&2
  exit 2
fi
playwright-cli open >/dev/null 2>&1 || true
# The pointer's script lives in the browser: close it when done, so the gate gets a clean one.
trap 'playwright-cli close >/dev/null 2>&1' EXIT
cursor_file="$FILMS/.cursor.js"
mkdir -p "$FILMS"
cursor_script > "$cursor_file"
playwright-cli run-code --filename "$cursor_file" >/dev/null 2>&1 || echo "film: no mouse pointer on the films (playwright-cli could not add it)" >&2
rm -f "$cursor_file"

failed=0
made=()
for name in "${names[@]}"; do
  film "$name" || failed=1
  [ -s "$FILMS/$name.mp4" ] && made+=("$FILMS/$name.mp4")
done
# --all: one film of everything, in order, when ffmpeg can join them.
if [ "$1" = "--all" ] && [ "${#made[@]}" -gt 1 ] && command -v ffmpeg >/dev/null 2>&1; then
  list="$FILMS/.all.txt"
  for file in "${made[@]}"; do printf "file '%s'\n" "$(basename "$file")"; done > "$list"
  ffmpeg -v error -y -f concat -safe 0 -i "$list" -c copy "$FILMS/all.mp4" && echo "all   -> $FILMS/all.mp4"
  rm -f "$list"
fi
exit "$failed"
