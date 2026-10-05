#!/usr/bin/env node
// Check that every page and ACT_ microflow of a module is named by a `# covers:` line in tests/verify-*.test.sh.
//
// Also fails on covers: names not in the model (not built yet, or renamed). Run by tests/gate.sh, tests/orient.sh and the exec hook.
// Usage: check_test_coverage.cjs <app-dir> <Module> [<Module>...] [--tests-dir tests] [--json]
// --json keys: verdict, module, elements, tests, untested, stale_covers (several modules: modules, stale_covers).
// Exit: 0 all covered, 1 something uncovered or stale, 2 the model could not be read.
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const py = require('./py_compat.cjs');

// `# covers: A, B, C`, and the `#` lines right under it that hold only more names: a long list
// wrapped over three lines counted its first line only, and the rest showed as untested.
// Names are separated by commas or spaces: a session wrote `# covers: A B C` and read 0/24
// covered with every test green. Group 1 is the list, continuation lines included.
const QUALIFIED_LIST = String.raw`[\w.]+\.\w+(?:(?:\s*,\s*|\s+)[\w.]+\.\w+)*\s*,?`;
const COVERS_RE = py.re.compile(String.raw`^\s*#\s*covers\s*:\s*(.+(?:\n\s*#\s*` + QUALIFIED_LIST + String.raw`\s*$)*)`, 'im');

function mxcliBinary(appDir) {
  if (py.exists(path.join(appDir, 'mxcli'))) return './mxcli';
  if (py.exists(path.join(appDir, 'mxcli.exe'))) return './mxcli.exe';
  return './mxcli';
}

class ModelReadError extends Error {}

// Rows of one MDL command's --json output; throws ModelReadError rather than returning [].
function mxcliJson(appDir, mpr, command) {
  const binary = mxcliBinary(appDir);
  const timeout = parseFloat(process.env.MDL_MXCLI_TIMEOUT || '120');
  const result = spawnSync(binary, ['-p', mpr, '--json', '-c', command], {
    cwd: appDir, encoding: 'utf8', timeout: timeout * 1000, maxBuffer: 1 << 30,
    windowsHide: true,
  });
  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') throw new ModelReadError(`\`${command}\` did not finish within ${timeout.toFixed(0)}s`);
    const why = py.WIN ? '[WinError 2] The system cannot find the file specified'
      : `[Errno 2] No such file or directory: '${binary}'`;
    throw new ModelReadError(`could not start mxcli: ${result.error.code === 'ENOENT' ? why : result.error.message}`);
  }
  const stdout = (result.stdout || '').replace(/\r\n?/g, '\n');
  const stderr = (result.stderr || '').replace(/\r\n?/g, '\n');
  if (result.status !== 0) {
    const why = py.splitlines(py.strip(stderr || stdout));
    const code = result.status === null ? -1 : result.status;
    throw new ModelReadError(`\`${command}\` exited ${code}: ${why.length ? why[why.length - 1] : 'no output'}`);
  }
  let rows;
  try {
    rows = JSON.parse(stdout);
  } catch {
    throw new ModelReadError(`\`${command}\` did not return JSON`);
  }
  if (!Array.isArray(rows)) throw new ModelReadError(`\`${command}\` did not return a list`);
  return rows;
}

// [all module names, the project's own modules].
function projectModules(appDir, mpr) {
  const rows = mxcliJson(appDir, mpr, 'SHOW MODULES');
  const every = new Set(rows.filter(r => r.Module).map(r => r.Module));
  const own = py.sorted(rows.filter(r => r.Module && !py.strip(r.Source || '') &&
    !['System', 'MyFirstModule'].includes(r.Module)).map(r => r.Module));
  return [every, own];
}

function qualifiedNames(rows) {
  const names = [];
  for (const row of rows) {
    const name = row['Qualified Name'] || row.QualifiedName;
    if (name) names.push(name);
  }
  return names;
}

// Names from a listing an older mxcli may not have: nothing, rather than a failed check.
function optionalNames(appDir, mpr, command, key = '') {
  let rows;
  try {
    rows = mxcliJson(appDir, mpr, command);
  } catch (error) {
    if (error instanceof ModelReadError) return [];
    throw error;
  }
  return key ? rows.filter(r => r[key]).map(r => r[key]) : qualifiedNames(rows);
}

// [required: pages and ACT_ microflows, known: any page, microflow, snippet or published
// service a test may name, entities: named on a covers: line, they get their own message].
function inventory(appDir, mpr, module) {
  const pages = qualifiedNames(mxcliJson(appDir, mpr, `SHOW PAGES IN ${module}`));
  const flows = qualifiedNames(mxcliJson(appDir, mpr, `SHOW MICROFLOWS IN ${module}`));
  const snippets = qualifiedNames(mxcliJson(appDir, mpr, `SHOW SNIPPETS IN ${module}`));
  // A test of an API covers the service: an OData test named Invoicing.InvoiceAPI and failed
  // coverage with "8/8 covered" on top, and the session rewrote this checker to get past it.
  const services = [...optionalNames(appDir, mpr, `SHOW ODATA SERVICES IN ${module}`),
    ...optionalNames(appDir, mpr, `SHOW PUBLISHED REST SERVICES IN ${module}`)];
  const entities = new Set(optionalNames(appDir, mpr, `SHOW ENTITIES IN ${module}`, 'Entity'));
  const required = py.sorted([...new Set([...pages, ...flows.filter(f => f.split('.').pop().startsWith('ACT_'))])]);
  const known = new Set([...pages, ...flows, ...snippets, ...services]);
  return [required, known, entities];
}

// The verify-*.test.sh scripts of a directory, sorted as pathlib sorts them.
function testScripts(dir) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const rx = py.WIN ? /^verify-.*\.test\.sh$/is : /^verify-.*\.test\.sh$/s;
  const found = names.filter(n => rx.test(n));
  return py.WIN ? py.sorted(found, n => n.toLowerCase()) : py.sorted(found);
}

function covered(testsDir) {
  const claims = new Map();
  if (!py.isdir(testsDir)) return claims;
  for (const name of testScripts(testsDir)) {
    const text = fs.readFileSync(path.join(testsDir, name)).toString('utf8').replace(/\r\n?/g, '\n');
    for (const match of COVERS_RE.finditer(text)) {
      for (let element of py.re.split(String.raw`[,\s]+`, py.re.sub(String.raw`\n\s*#`, ',', match.group(1)))) {
        element = py.strip(element);
        if (element) {
          if (!claims.has(element)) claims.set(element, []);
          claims.get(element).push(name);
        }
      }
    }
  }
  return claims;
}

// One module's verdict; with a single module every stale claim is reported under it.
function moduleReport(module, required, claims, stale, single) {
  const untested = required.filter(e => !claims.has(e));
  const prefix = module + '.';
  const mine = single ? stale : stale.filter(n => n.startsWith(prefix));
  const tests = new Set();
  for (const [name, scripts] of claims) if (name.startsWith(prefix)) for (const s of scripts) tests.add(s);
  return {
    verdict: !untested.length && !mine.length ? 'PASS' : 'FAIL',
    module,
    elements: required.length,
    tests: py.sorted([...tests]),
    untested,
    stale_covers: mine,
  };
}

const COVERABLE = 'pages, snippets, microflows and published OData/REST services';

// Why a covers: name counts for nothing -- the line the session reads to fix it.
function staleReason(name, entities) {
  if (entities.has(name)) {
    return `  - covers: names ${name}, an entity -- a covers: line lists ${COVERABLE}; name the page or ` +
      'microflow the test drives instead';
  }
  return `  - covers: names ${name}, which is not in the model (not built yet, or renamed) -- it lists ${COVERABLE}, ` +
    'separated by commas or spaces';
}

function printText(reports, orphans, entities = new Set()) {
  for (const report of reports) {
    const total = report.elements, missing = report.untested.length;
    if (total === 0 && !report.stale_covers.length) {
      py.print(`PASS  ${report.module}: nothing a user can reach (no page, no ACT_ microflow)`);
      continue;
    }
    // "FAIL ... 8/8 covered" alone read as a contradiction: say what the failure is.
    const stale = report.stale_covers.length;
    const why = stale && !missing ? `, but ${stale} covers: name(s) count for nothing` : '';
    py.print(`${report.verdict}  ${report.module}: ${total - missing}/${total} ` +
      `elements covered by ${report.tests.length} test script(s)${why}`);
    for (const element of report.untested) py.print(`  - no test covers ${element}`);
    for (const name of report.stale_covers) py.print(staleReason(name, entities));
  }
  if (orphans.length) {
    py.print('FAIL  covers: lines name elements in no module of this project');
    for (const name of orphans) py.print(staleReason(name, entities));
  }
}

const USAGE = 'usage: check_test_coverage.cjs [-h] [--tests-dir TESTS_DIR] [--json] app_dir Module [Module ...]';

function parseArgs(argv) {
  const positional = [];
  let testsDir = 'tests', json = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') json = true;
    else if (a === '--tests-dir') {
      if (i + 1 >= argv.length) usageError('argument --tests-dir: expected one argument');
      testsDir = argv[++i];
    } else if (a.startsWith('--tests-dir=')) testsDir = a.slice('--tests-dir='.length);
    else if (a === '-h' || a === '--help') { process.stdout.write(USAGE + '\n'); process.exit(0); }
    else positional.push(a);
  }
  if (positional.length < 2) usageError('the following arguments are required: ' + (positional.length ? 'Module' : 'app_dir, Module'));
  return { appDir: positional[0], modules: positional.slice(1), testsDir, json };
}
function usageError(message) {
  process.stderr.write(`${USAGE}\ncheck_test_coverage.cjs: error: ${message}\n`);
  process.exit(2);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const appDir = args.appDir;
  let mprs = [];
  try {
    const rx = py.WIN ? /^.*\.mpr$/is : /^.*\.mpr$/s;
    mprs = py.sorted(fs.readdirSync(appDir).filter(n => rx.test(n)), py.WIN ? n => n.toLowerCase() : null);
  } catch { /* no directory */ }
  if (!mprs.length) {
    py.print(`ERROR  no .mpr in ${appDir}`);
    return 2;
  }
  const mpr = mprs[0];

  let every, own, inventories;
  try {
    [every, own] = projectModules(appDir, mpr);
    const unknown = args.modules.filter(m => !every.has(m));
    if (unknown.length) {
      py.print(`ERROR  no module named ${unknown.join(', ')} in ${mpr}`);
      return 2;
    }
    inventories = new Map();
    for (const module of py.sorted([...new Set([...own, ...args.modules])])) inventories.set(module, inventory(appDir, mpr, module));
  } catch (error) {
    if (!(error instanceof ModelReadError)) throw error;
    py.print(`ERROR  could not read the model: ${error.message}`);
    return 2;
  }

  const known = new Set(), entities = new Set();
  for (const [, names, moduleEntities] of inventories.values()) {
    for (const n of names) known.add(n);
    for (const e of moduleEntities) entities.add(e);
  }

  const claims = covered(path.join(appDir, args.testsDir));
  const stale = py.sorted([...claims.keys()].filter(n => !known.has(n)));
  const single = args.modules.length === 1;

  const reports = args.modules.map(m => moduleReport(m, inventories.get(m)[0], claims, stale, single));
  // With several modules, stale names outside all of them are reported once, separately.
  const checked = new Set(args.modules);
  const orphans = single ? [] : stale.filter(n => !checked.has(n.split('.')[0]));

  if (args.json) {
    const payload = single ? reports[0] : { modules: reports, stale_covers: orphans };
    py.print(py.jsonDumps(payload, { indent: 2 }));
  } else {
    printText(reports, orphans, entities);
  }

  const failed = orphans.length || reports.some(r => r.verdict === 'FAIL');
  return failed ? 1 : 0;
}

// gate_helpers.cjs test-first reads the model and the covers: lines the same way.
if (require.main === module) process.exitCode = main();
module.exports = { mxcliJson, qualifiedNames, projectModules, covered, ModelReadError };
