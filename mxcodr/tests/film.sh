#!/usr/bin/env bash
# tests/film.sh -- a video of a browser test's run, with the test's name on it.
#
#   bash tests/film.sh --list                 # every test: what it walks through, who signs in
#   bash tests/film.sh mastermind             # tests/verify-mastermind.test.sh -> .mxcli/films/mastermind.mp4
#   bash tests/film.sh --pace 1500 orders     # slower: ms the pointer waits around each action (default 1000, 0 = test speed)
#
# One test per film, one film per run: a whole suite, slowed to be watched, took 11 minutes and
# outlived the app's licensed run time halfway through.
#
# The test runs unchanged in the browser the tests share, slowed for the eye: before each click,
# fill or pick the pointer goes to the element, and a pause follows (lib/scenario.sh,
# MDL_FILM_PACE_MS). playwright-cli records that browser and opens the film with a card naming the test.
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

# The steps the scenario took, one per line, as lib/scenario.sh noted them while paced
# (`Click "New order"`, `Type in "Quantity"` -- labels only, never what was typed).
read_steps() {
  playwright-cli run-code "async page => JSON.stringify(Object.getPrototypeOf(page).__mdlFilmSteps || [])" 2>/dev/null \
    | "$NODE" -e '
      let text = ""; process.stdin.on("data", d => text += d).on("end", () => {
        const at = text.indexOf("### Result");
        if (at < 0) return;
        const line = text.slice(at).split("\n")[1] || "";
        try {
          const steps = JSON.parse(JSON.parse(line));
          if (Array.isArray(steps)) for (const step of steps) console.log(String(step));
        } catch (e) {}
      });'
}

# slide <name> <steps file> <png> -- one page: the test's name and its numbered steps, in two
# columns past 15, at most 30 (the rest counted below), drawn by a browser of its own.
slide() {
  local code="$FILMS/.slide.js"
  # playwright-cli refuses file: URLs, so the page is set as content in a run-code script.
  local target="$3"
  case "$target" in show:*) ;; *) target="$PWD/$target" ;; esac
  "$NODE" - "$1" "$2" "$target" > "$code" <<'JS' || return 1
const fs = require('fs');
const [name, file, target] = process.argv.slice(2);
// A run of the same step, or the same pair of steps, is one line: `Click "Advance status",
// Click "Dismiss" (4 times)`.
const raw = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
const all = [];
for (let i = 0; i < raw.length;) {
  let done = false;
  for (const k of [1, 2]) {
    let n = 1;
    while (raw.slice(i + n * k, i + (n + 1) * k).join('\u0000') === raw.slice(i, i + k).join('\u0000')) n++;
    if (n > 1) { all.push(`${raw.slice(i, i + k).join(', ')} (${n} times)`); i += n * k; done = true; break; }
  }
  if (!done) { all.push(raw[i]); i++; }
}
const MAX = 30;
const steps = all.slice(0, MAX);
const more = all.length > MAX ? `<p class="more">... and ${all.length - MAX} more steps</p>` : '';
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const two = steps.length > 15;
const size = two ? 22 : steps.length > 12 ? 24 : 26;
const html = (`<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:100%;min-height:100%;background:#1f2933;color:#f5f7fa;font-family:-apple-system,"Segoe UI",Helvetica,Arial,sans-serif}
main{padding:56px 80px}h1{margin:0 0 6px;font-size:40px}p{margin:0 0 28px;color:#9aa5b1;font-size:20px}
ol{margin:0;padding-left:44px;font-size:${size}px;line-height:1.5;column-count:${two ? 2 : 1};column-gap:60px}
li{break-inside:avoid}li::marker{color:#9aa5b1}.more{margin-top:18px}</style>
<main><h1>${esc(name)}</h1><p>What this test does, step by step</p><ol>${steps.map(s => `<li>${esc(s)}</li>`).join('')}</ol>${more}</main>`);
// show:<ms> -- on the page being filmed, for that long (no ffmpeg); else a 1280x800 picture.
process.stdout.write(target.startsWith('show:')
  ? `async page => { await page.setContent(${JSON.stringify(html)}); await page.waitForTimeout(${Number(target.slice(5)) || 6000}); }\n`
  : `async page => {
  await page.setViewportSize({width: 1280, height: 800});
  await page.setContent(${JSON.stringify(html)});
  await page.screenshot({path: ${JSON.stringify(target)}});
}\n`);
JS
  if [ "${3#show:}" != "$3" ]; then
    playwright-cli run-code --filename "$code" >/dev/null 2>&1
    rm -f "$code"
    return 0
  fi
  playwright-cli -s=mxcodr-film-slide open >/dev/null 2>&1 || return 1
  playwright-cli -s=mxcodr-film-slide run-code --filename "$code" >/dev/null 2>&1
  playwright-cli -s=mxcodr-film-slide close >/dev/null 2>&1
  rm -f "$code"
  [ -s "$3" ]
}

# prepend_slide <name> -- put the step page in front of <name>.mp4, on screen long enough to read.
prepend_slide() {
  local name="$1" steps="$FILMS/.$1.steps" png="$FILMS/.$1.png" count seconds
  read_steps > "$steps"
  count="$(grep -c . "$steps")"
  if [ "$count" = "0" ] || ! slide "$name" "$steps" "$png"; then rm -f "$steps" "$png"; return 0; fi
  [ "$count" -gt 30 ] && count=30
  seconds=$(( 3 + count / 2 ))
  ffmpeg -v error -y -loop 1 -t "$seconds" -i "$png" -c:v libx264 -pix_fmt yuv420p -r 25 \
    -vf 'scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2' "$FILMS/.$name.slide.mp4" \
    && printf "file '.%s.slide.mp4'\nfile '%s.mp4'\n" "$name" "$name" > "$FILMS/.$name.list" \
    && ffmpeg -v error -y -f concat -safe 0 -i "$FILMS/.$name.list" -c copy -movflags +faststart "$FILMS/.$name.joined.mp4" \
    && mv "$FILMS/.$name.joined.mp4" "$FILMS/$name.mp4"
  rm -f "$steps" "$png" "$FILMS/.$name.slide.mp4" "$FILMS/.$name.list" "$FILMS/.$name.joined.mp4"
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
  playwright-cli run-code "async page => { Object.getPrototypeOf(page).__mdlFilmSteps = []; }" >/dev/null 2>&1
  sleep 2
  # Slowed, a test takes longer than the gate's limit allows: give it ten times as long.
  out="$(BASE_URL="$BASE_URL" MDL_FILM_PACE_MS="$PACE" SCRIPT_TIMEOUT=900 bash "$script" 2>&1)"; status=$?
  sleep 1
  # No ffmpeg to put the step page in front: the browser shows it at the end of the recording.
  if ! command -v ffmpeg >/dev/null 2>&1; then
    local steps="$FILMS/.$name.steps" count
    read_steps > "$steps"
    count="$(grep -c . "$steps")"
    [ "$count" -gt 30 ] && count=30
    [ "$count" != "0" ] && slide "$name" "$steps" "show:$(( (3 + count / 2) * 1000 ))"
    rm -f "$steps"
  fi
  playwright-cli video-stop >/dev/null 2>&1
  if [ ! -s "$FILMS/$name.webm" ]; then
    echo "film: $name ran, but no film was written" >&2
    return 2
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    # One frame size for every film, whatever size the page had.
    ffmpeg -v error -y -i "$FILMS/$name.webm" -c:v libx264 -pix_fmt yuv420p -movflags +faststart -r 25 \
      -vf 'scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:white' "$FILMS/$name.mp4" \
      || rm -f "$FILMS/$name.mp4"
    # The step page goes first; a test run at --pace 0 notes no steps and gets none.
    [ -s "$FILMS/$name.mp4" ] && prepend_slide "$name"
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
    sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  --list)
    list_tests
    exit 0 ;;
esac

PACE=1000
if [ "${1:-}" = "--pace" ]; then
  case "${2:-}" in
    ''|*[!0-9]*) echo "film: --pace takes milliseconds, e.g. --pace 1500 (0 = the test's own speed)" >&2; exit 2 ;;
  esac
  PACE="$2"; shift 2
fi
if [ "$#" -ne 1 ] || [ "${1#-}" != "$1" ]; then
  echo "film: name one test (bash tests/film.sh --list shows them); one film per run" >&2
  exit 2
fi
name="${1#verify-}"; name="${name%.test.sh}"
if [ ! -f "tests/verify-$name.test.sh" ]; then
  echo "film: no test named '$name'. The tests here: $(for s in tests/verify-*.test.sh; do printf '%s ' "$(name_of "$s")"; done)" >&2
  exit 2
fi
films_something "tests/verify-$name.test.sh" || { echo "film: $name opens no browser -- nothing to film" >&2; exit 2; }

# One browser for every test, the gate and every film: never record over a run that uses it.
if pgrep -f 'tests/gate\.sh|tests/film\.sh|mxcli playwright verify|verify-[A-Za-z0-9_-]*\.test\.sh' 2>/dev/null | grep -qvx "$$"; then
  echo "film: a gate, a test or another film is running and holds the shared browser -- film when it is done" >&2
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

film "$name"
