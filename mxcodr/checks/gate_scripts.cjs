// gate_helpers duplicate-definitions (SCRIPT01), test-first (TEST01) and new-features (REQ01): what MDL
// scripts create.
'use strict';
const fs = require('fs');
const py = require('./py_compat.cjs');
const { re } = py;
const { or, readReplace, abspath } = require('./gate_values.cjs');

const DEFINITION_RE = re.compile(
  String.raw`^[ \t]*create\s+(?:or\s+(?:modify|replace)\s+)?(?:(?:persistent|non-persistent|view|external)\s+)?` +
  String.raw`(?P<kind>page|snippet|layout|microflow|nanoflow|entity|enumeration|workflow|menu|constant)\s+` +
  String.raw`(?P<name>[\w"]+\.[\w"]+)`, 'im');

// Map of 'kind\0name' -> [kind, name] a script creates.
function definitions(file) {
  const found = new Map();
  let text;
  try {
    text = readReplace(file);
  } catch {
    return found;
  }
  for (const m of DEFINITION_RE.finditer(text)) {
    const kind = m.group('kind').toLowerCase(), name = m.group('name').split('"').join('');
    found.set(kind + '\0' + name, [kind, name]);
  }
  return found;
}

// TEST01: test first. A page or ACT_ microflow these scripts create that the model does not have
// yet, and that no `# covers:` line of tests/verify-*.test.sh names: one per line. The tests came
// last in every session so far -- the skill says test first, the gate checks coverage only at the
// end, and a session built the whole app, then wrote six tests in one go, three of which had never
// failed (InvoiceChaseCodr, 2026-10-05). Blocking the exec here makes the test come before the page,
// when the script that names its widgets is already written. A document that is already in the
// model (a fix to it) passes; so does anything the model cannot be read for -- never a false block.
// The pages and ACT_ microflows these scripts create that the model does not have yet, in the
// project's own modules: [[kind, name]...], or null when the model cannot be read (never a false block).
function newFeatures(app, mpr, scripts, coverage = require('./check_test_coverage.cjs')) {
  const wanted = [];
  for (const script of scripts) {
    for (const [kind, name] of definitions(script).values()) {
      const leaf = name.split('.').pop();
      if (kind === 'page' || (kind === 'microflow' && leaf.startsWith('ACT_'))) wanted.push([kind, name]);
    }
  }
  if (!wanted.length) return [];
  let every, own, existing;
  try {
    [every, own] = coverage.projectModules(app, mpr);
    existing = new Set([...coverage.qualifiedNames(coverage.mxcliJson(app, mpr, 'SHOW PAGES')),
      ...coverage.qualifiedNames(coverage.mxcliJson(app, mpr, 'SHOW MICROFLOWS'))]);
  } catch {
    return null;
  }
  const seen = new Set();
  return wanted.filter(([, name]) => {
    const module = name.split('.')[0];
    // The project's own modules, or one these scripts create: never a Marketplace module or System.
    // MyFirstModule counts as the project's: projectModules() leaves the template out for coverage,
    // and a session that built its whole screen there walked past this check (Qwen 3.6 Splash,
    // InvoiceChase2, 2026-10-06).
    if (every.has(module) && !own.includes(module) && module !== 'MyFirstModule') return false;
    if (existing.has(name) || seen.has(name)) return false;
    seen.add(name);
    return true;
  });
}

function testFirst(args) {
  const [app, mpr, ...scripts] = args;
  const coverage = require('./check_test_coverage.cjs');
  const fresh = newFeatures(app, mpr, scripts, coverage);
  if (!fresh || !fresh.length) return 0;
  let claims;
  try {
    claims = coverage.covered(py.join(app, 'tests'));
  } catch {
    return 0;
  }
  for (const [kind, name] of fresh) if (!claims.has(name)) py.print(`  - ${kind} ${name}`);
  return 0;
}

// REQ01: the first page or ACT_ microflow of an app waits for the requirements. B2B part 1
// (InvoiceB2BG1, 2026-10-12): the session never opened the interview, built the whole app, and after
// a warning captured seven requirements for a nine-section request -- the dates and amounts it
// asked for in DD/MM/YYYY and with a thousands separator were in none, so no test asked for them and
// the gate said DONE. Prints what these scripts would add; the caller decides whether the plan is empty.
// Only while the app has no page of its own yet: an app that grew without a brain gets the after-exec
// warning instead, not a block on its next page.
function newFeaturesCommand(args) {
  const [app, mpr, ...scripts] = args;
  const coverage = require('./check_test_coverage.cjs');
  const fresh = newFeatures(app, mpr, scripts, coverage);
  if (!fresh || !fresh.length) return 0;
  try {
    const own = coverage.projectModules(app, mpr)[1];
    const pages = coverage.qualifiedNames(coverage.mxcliJson(app, mpr, 'SHOW PAGES'));
    if ([...pages].some(name => own.includes(name.split('.')[0]))) return 0;
  } catch {
    return 0;
  }
  for (const [kind, name] of fresh) py.print(`  - ${kind} ${name}`);
  return 0;
}


// SCRIPT01: a document two scripts create is whatever the last one run says.
// The kinds mxcli 0.25 can patch with `alter <kind>`; a constant or a menu it cannot.
const ALTERABLE = new Set(['entity', 'enumeration', 'page', 'snippet', 'microflow', 'nanoflow', 'workflow']);
function duplicateDefinitions(scripts) {
  const reported = new Set();
  for (const script of scripts) {
    const own = definitions(script);
    if (!own.size) continue;
    const folder = py.dirname(script) || '.';
    // Only the owner scripts in mdlsource/: a one-off elsewhere (tools/once/) is history once it ran,
    // and an older one-off that created the same flow blocked every repair after it -- three times in
    // one InvoiceChase session (2026-10-09). Overwriting newer work is STALE01's to catch.
    if (py.basename(abspath(folder)) !== 'mdlsource') continue;
    const names = fs.readdirSync(folder).sort(py.compare);
    for (const other of names) {
      const file = py.join(folder, other);
      if (!other.endsWith('.mdl') || abspath(file) === abspath(script)) continue;
      const theirs = definitions(file);
      const both = [...own.entries()].filter(([k]) => theirs.has(k)).map(([, v]) => v);
      both.sort((a, b) => py.compare(a[0], b[0]) || py.compare(a[1], b[1]));
      for (const [kind, name] of both) {
        const pair = [abspath(script), abspath(file)].sort(py.compare);
        const key = [kind, name, ...pair].join('\0');
        if (reported.has(key)) continue;
        reported.add(key);
        py.print(`  - ${kind} ${name} is created in ${script} and in ${file}: whichever runs last decides what the ${kind} is, and ` +
          're-running the other silently undoes it. Keep ONE `create` of it, in one script, and ' +
          (ALTERABLE.has(kind) ? `change it there (or with \`alter ${kind}\`).`
            : `change it there and exec that script again -- mxcli has no \`alter ${kind}\`.`));
      }
    }
  }
  return 0;
}

// The lines a --watch boot writes, in the order they can follow one another.

// The icons of a collection closest to a name that is not in it, from `describe icon collection`
// on stdin: a session guessed "chart-bar", "user-badge" and "shopping-bag" in Atlas_Filled and was
// refused three times, each time told only that the name does not exist (InvoiceB2BG1, 2026-10-12).
// Words shared with the guess count most, then a guess word inside an icon word ("chart" in
// "analytics-graph-bar" does not match; "bar" does). At most six, best first; none when nothing is near.
function nearIcons(name, listing) {
  const icons = [...new Set([...String(listing).matchAll(/^\|\s*([A-Za-z0-9][\w-]*)\s*\|/gm)].map(m => m[1]))]
    .filter(icon => icon !== 'Icon');
  const words = t => t.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  const want = words(name);
  const scored = icons.map(icon => {
    const have = words(icon);
    let score = 0;
    for (const w of want) {
      if (have.includes(w)) score += 3;
      else if (w.length >= 3 && have.some(h => h.startsWith(w) || w.startsWith(h) && h.length >= 3)) score += 1;
    }
    return [score, icon];
  }).filter(([score]) => score > 0);
  scored.sort((a, b) => b[0] - a[0] || a[1].length - b[1].length || (a[1] < b[1] ? -1 : 1));
  return scored.slice(0, 6).map(([, icon]) => icon);
}

function nearIconsCommand(args) {
  const listing = fs.readFileSync(0, 'utf8');
  py.print(nearIcons(args[0] || '', listing).join(' '));
  return 0;
}

// Where each build error sits in the scripts: mxbuild names the activity or widget ("Error(s) in
// expression." at Change variable activity 'Write the buyer block') but never the expression, and a
// session read the script back to find it, error after error -- CE0117 eleven times in one run
// (InvoiceB2BG2, 2026-10-12). For each error line on stdin, the first script line naming it: a
// `@caption '<name>'` with the statement under it, or the widget or document of that name.
function errorSources(scripts, errors) {
  const files = scripts.map(script => {
    try { return [script, fs.readFileSync(script, 'utf8').split(/\r?\n/)]; } catch { return [script, []]; }
  });
  const out = [], seen = new Set();
  for (const error of String(errors).split(/\r?\n/)) {
    const m = /\] .* at [^']*'([^']+)'/.exec(error);
    if (!m || seen.has(m[1])) continue;
    seen.add(m[1]);
    const name = m[1], quoted = "'" + name.replace(/'/g, "''") + "'";
    const word = new RegExp('(^|[^\\w.])' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '([^\\w]|$)');
    found: for (const [script, lines] of files) {
      for (let n = 0; n < lines.length; n++) {
        const line = lines[n];
        const caption = /^\s*@caption\s/i.test(line) && line.includes(quoted);
        if (!caption && !(/\w/.test(name) && !name.includes(' ') && word.test(line))) continue;
        let shown = `     ${script}:${n + 1}: ${line.trim()}`;
        if (caption) {
          let k = n + 1;
          while (k < lines.length && (!lines[k].trim() || /^\s*@/.test(lines[k]))) k++;
          if (k < lines.length) shown += `\n     ${script}:${k + 1}: ${lines[k].trim()}`;
        }
        out.push(`  '${name}':\n${shown}`);
        break found;
      }
    }
    if (out.length >= 8) break;
  }
  return out;
}

function errorSourcesCommand(args) {
  const lines = errorSources(args, fs.readFileSync(0, 'utf8'));
  if (lines.length) py.print('  where they are in the scripts:\n' + lines.join('\n'));
  return 0;
}

// MSG01: `show message ... type warning` (or error, information) in lower case. mxcli v0.26 stores the word
// as written, and the first tool that saves the model again -- `mxcli fix widgets`, which the after-exec
// hook runs for a data grid, or Studio Pro -- reads an unknown type and makes it Information: the
// warning is shown as plain information, and the script no longer matches the model (STALE01 refused
// three re-runs of an untouched script, room booking 2026-10-13). Warning and Error with a capital stay.
const MESSAGE_TYPE_RE = /\bshow\s+message\b[^;]*?\btype\s+(information|warning|error)\b/g;
function lowerCaseMessageTypes(scripts) {
  const out = [];
  for (const script of scripts) {
    let text;
    try { text = fs.readFileSync(script, 'utf8'); } catch { continue; }
    text.split(/\r?\n/).forEach((line, i) => {
      for (const m of line.matchAll(MESSAGE_TYPE_RE)) {
        const fixed = m[1][0].toUpperCase() + m[1].slice(1);
        out.push(`  ${script}:${i + 1}: \`type ${m[1]}\` -> \`type ${fixed}\``);
      }
    });
  }
  if (out.length) process.stdout.write(out.join('\n') + '\n');
}

module.exports = { DEFINITION_RE, definitions, testFirst, newFeatures, newFeaturesCommand, nearIcons, nearIconsCommand, errorSources, errorSourcesCommand, ALTERABLE, duplicateDefinitions, lowerCaseMessageTypes };
