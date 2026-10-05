// After an `mxcli exec`: what the scripts it ran put back that another script had changed.
//
//     node script_overrides.cjs --command '<the shell command>'
//
// Reads the .mdl scripts the command names and the other .mdl scripts beside them. Re-running an
// older script undoes a later one: `create or modify page` drops every `alter page` another script
// made to that page, and a `grant` puts back access another script revoked. InvoiceB2B
// (2026-10-04): re-running 07_dashboard.mdl granted the Dashboard to Employee again, which
// 20_access.mdl had taken away, and a test failed on it. Prints the advice, or nothing. Exit 0.
'use strict';
const path = require('path');
const py = require('./py_compat.cjs');
const { re } = py;

const KIND = '(microflow|nanoflow|page|snippet)';
const DOC_GRANT = re.compile(String.raw`^\s*grant\s+(execute|view)\s+on\s+${KIND}\s+([\w.]+)\s+to\s+([^;]+);`, 'i');
const DOC_REVOKE = re.compile(String.raw`^\s*revoke\s+(execute|view)\s+on\s+${KIND}\s+([\w.]+)\s+from\s+([^;]+);`, 'i');
const ENTITY_GRANT = re.compile(String.raw`^\s*grant\s+([\w.]+)\s+on\s+([\w.]+)\s*\(`, 'i');
const ENTITY_REVOKE = re.compile(String.raw`^\s*revoke\s+([\w.]+)\s+on\s+([\w.]+)\s*;`, 'i');
const CREATE_PAGE = re.compile(String.raw`^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(page|snippet)\s+([\w.]+)`, 'i');
const ALTER_PAGE = re.compile(String.raw`^\s*alter\s+(page|snippet)\s+([\w.]+)`, 'i');

const roles = text => text.split(',').map(r => py.strip(r)).filter(Boolean);
const keyOf = key => (Array.isArray(key) ? JSON.stringify(key) : key);

function read(file) {
  try {
    return py.readText(file);
  } catch {
    return null;
  }
}

// [[op, key]] in script order: op is grant, revoke, create or alter.
function operations(file) {
  const text = read(file);
  if (text === null) return [];
  const found = [];
  for (const line of py.splitlines(text)) {
    let m = DOC_GRANT.match(line);
    if (m) {
      for (const role of roles(m.group(4))) found.push(['grant', [`${m.group(1).toLowerCase()} on ${m.group(2).toLowerCase()} ${m.group(3)}`, role]]);
      continue;
    }
    m = DOC_REVOKE.match(line);
    if (m) {
      for (const role of roles(m.group(4))) found.push(['revoke', [`${m.group(1).toLowerCase()} on ${m.group(2).toLowerCase()} ${m.group(3)}`, role]]);
      continue;
    }
    m = ENTITY_GRANT.match(line);
    if (m) { found.push(['grant', [`access to ${m.group(2)}`, m.group(1)]]); continue; }
    m = ENTITY_REVOKE.match(line);
    if (m) { found.push(['revoke', [`access to ${m.group(2)}`, m.group(1)]]); continue; }
    m = CREATE_PAGE.match(line);
    if (m) { found.push(['create', `${m.group(1).toLowerCase()} ${m.group(2)}`]); continue; }
    m = ALTER_PAGE.match(line);
    if (m) found.push(['alter', `${m.group(1).toLowerCase()} ${m.group(2)}`]);
  }
  return found;
}

const SET = re.compile(String.raw`^set\s+(?:\((?P<many>.*)\)|(?P<one>.+?))\s+on\s+(?P<widget>\w+)\s*;?$`, 'is');

// The text between the parentheses of `<type> <widget> ( ... )` in a page source, or ''.
function widgetProperties(source, widget) {
  const start = re.search(String.raw`\b${re.escape(widget)}\s*\(`, source);
  if (!start) return '';
  let depth = 1, at = start.end();
  while (at < source.length && depth) {
    depth += { '(': 1, ')': -1 }[source[at]] || 0;
    at++;
  }
  return source.slice(start.end(), at - 1);
}

// The statements inside the `alter <page|snippet> <name> { ... };` blocks of <file>.
function alterBlock(file, key) {
  const space = key.indexOf(' ');
  const kind = key.slice(0, space), name = key.slice(space + 1);
  const text = read(file);
  if (text === null) return [];
  const found = [];
  for (const block of re.finditer(String.raw`^\s*alter\s+${kind}\s+${re.escape(name)}\s*\{(?P<body>.*?)^\s*\};?`, text, 'ims')) {
    for (const part of block.group('body').split(';')) {
      const p = py.strip(part);
      if (p && !p.startsWith('--')) found.push(p);
    }
  }
  return found;
}

// True when the alter only sets properties, and the creating script already has each value:
// a session moved `set (Height = 360) on chart` into the page source and kept the old alter.
function alreadyIn(alterPath, key, createPath) {
  const statements = alterBlock(alterPath, key);
  const source = read(createPath);
  if (source === null) return false;
  if (!statements.length) return false;
  for (const statement of statements) {
    const m = SET.match(statement);
    if (!m) return false;        // insert, drop, replace: the page source cannot be compared
    // The value must be on that widget: `Height: 360` on another one hid a lost alter.
    const properties = widgetProperties(source, m.group('widget'));
    for (const pair of re.split(String.raw`,\s*(?=\w+\s*=)`, m.group('many') || m.group('one'))) {
      const eq = pair.indexOf('=');
      const prop = eq < 0 ? pair : pair.slice(0, eq), value = eq < 0 ? '' : pair.slice(eq + 1);
      if (!re.search(String.raw`\b${re.escape(py.strip(prop))}\s*:\s*${re.escape(py.strip(value))}`, properties, 'i')) return false;
    }
  }
  return true;
}

function scriptsIn(command) {
  // punctuation_chars splits `;`, `&&` and `|` off a word: `for f in a.mdl b.mdl; do` named
  // `b.mdl;`, which is no file, so the last script of a loop did not count as run (2026-10-04).
  let words;
  try {
    const lexer = new py.Shlex(command, true);
    lexer.whitespaceSplit = true;
    words = lexer.all();
  } catch {
    words = py.split(command);
  }
  const paths = [];
  for (const word of words) {
    const candidates = /[*?[]/.test(word) ? py.sorted(py.glob(word)).slice(0, 200) : [word];
    for (const p of candidates) {
      if (p.endsWith('.mdl') && py.isfile(p) && !paths.includes(p)) paths.push(p);
    }
  }
  return paths;
}

const abspath = p => py.normpath(path.isAbsolute(p) ? p : process.cwd() + '/' + p);

// What the scripts, replayed in name order (01_, 02_, ...), leave changed that this exec undid.
function findings(executed) {
  const net = new Map();
  for (const file of executed) for (const [op, key] of operations(file)) net.set(keyOf(key), [op, key]);
  const run = new Set(executed.map(abspath));
  const everySet = new Set(run);
  for (const script of executed) {
    for (const p of py.glob(py.join(py.dirname(script) || '.', '*.mdl'))) everySet.add(abspath(p));
  }
  const every = py.sorted([...everySet], p => py.basename(p));
  const final = new Map();   // key -> [op, script] after replaying every script in order
  const alters = new Map();  // page -> [scripts that alter it after its last create]
  const creator = new Map(); // page -> the script that creates it last
  for (const file of every) {
    for (const [op, key] of operations(file)) {
      final.set(keyOf(key), [op, file]);
      if (op === 'create') { alters.set(key, []); creator.set(key, file); }
      else if (op === 'alter') { if (!alters.has(key)) alters.set(key, []); alters.get(key).push(file); }
    }
  }
  // `net` is what this exec left, in the order it ran; `final` is what the scripts leave in name
  // order. A grant or a create that came last here undid the later script, also when that script
  // was part of this exec but ran first (`exec 20_access.mdl 07_dashboard.mdl`).
  const found = [];
  for (const [k, [op, key]] of net) {
    if (op === 'grant' && (final.get(k) || ['', ''])[0] === 'revoke') {
      const [what, role] = key;
      const name = py.basename(final.get(k)[1]);
      const how = run.has(final.get(k)[1]) ? 'this exec ran it before the script that grants' : 'this exec granted';
      found.push(`${name} revokes ${what} from ${role}; ${how} it again`);
    } else if (op === 'create') {
      for (const file of alters.get(key) || []) {
        if (!alreadyIn(file, key, creator.get(key))) {
          const how = run.has(file) ? 'this exec ran it before the script that re-creates' : 'this exec re-created';
          found.push(`${py.basename(file)} alters ${key}; ${how} the ${key.split(' ')[0]} without that change`);
        }
      }
    }
  }
  return [...new Set(found)];
}

function main(argv) {
  if (argv.length !== 2 || argv[0] !== '--command') {
    process.stderr.write('After an `mxcli exec`: what the scripts it ran put back that another script had changed.\n');
    return 0;
  }
  const executed = scriptsIn(argv[1]);
  if (!executed.length) return 0;
  const found = findings(executed);
  if (found.length) {
    py.print('That exec put back what another script had changed:');
    for (const line of found.slice(0, 8)) py.print('   - ' + line);
    if (found.length > 8) py.print(`   ... 8 of ${found.length} shown`);
    py.print('   Exec those scripts again after this one, or move their change into the script that ' +
      'owns the page or the rule, so re-running it keeps the change.');
  }
  return 0;
}

process.exitCode = main(process.argv.slice(2));
