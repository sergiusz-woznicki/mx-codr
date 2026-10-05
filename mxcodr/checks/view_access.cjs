// VIEW01: a view entity that hands a row-scoped role every row of the data it summarises.
//
//     node view_access.cjs <entities.mdl> [--expect <entities described>]
//
// <entities.mdl> is DESCRIBE ENTITY output for the project's own entities, one after another.
// A role that reads only its own rows of an entity (an access rule with an XPath constraint) must
// not read a view over that entity without a constraint: the view returns the
// totals of every customer. InvoiceB2B (2026-10-04) granted its Customer role `read *` on two
// views that sum every customer's orders and invoices, while the same role saw only its own
// invoices. Prints one line per finding; exit 1 when there is one, 0 when none, 2 when it could
// not run.
'use strict';
const py = require('./py_compat.cjs');
const { re } = py;

const HEAD = re.compile(String.raw`^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?P<kind>view\s+|(?:non-)?persistent\s+)?` +
  String.raw`entity\s+(?P<name>\w+\.(?:"[^"]+"|\w+))`, 'i');
// Names may be quoted (Orders."Order"): the heads and grants read them as the query's sources do.
const GRANT = re.compile(String.raw`^\s*grant\s+(?P<role>[\w.]+)\s+on\s+(?P<entity>\w+\.(?:"[^"]+"|\w+))\s*\((?P<rights>[^)]*)\)` +
  String.raw`(?P<where>\s+where\s+')?`, 'i');
const SOURCE = re.compile(String.raw`\b(?:from|join)\s+(?P<entity>\w+\.(?:"[^"]+"|\w+))`, 'i');

const name = text => text.split('"').join('');
const keyOf = (role, entity) => JSON.stringify([role, entity]);

// [{view: [entities its query reads]}, {(role, entity): constrained?} for rules that read].
function read(lines) {
  const views = new Map();
  const rules = new Map();
  let current = null, inQuery = false;
  for (const line of lines) {
    const head = HEAD.match(line);
    if (head) {
      current = name(head.group('name'));
      inQuery = Boolean(head.group('kind')) && head.group('kind').toLowerCase().startsWith('view');
      if (inQuery) views.set(current, []);
      continue;
    }
    const grant = GRANT.match(line);
    if (grant) {
      inQuery = false;
      if (grant.group('rights').toLowerCase().includes('read')) {
        const key = keyOf(grant.group('role'), name(grant.group('entity')));
        // Two rules for one role: the unconstrained one wins, as at runtime.
        rules.set(key, (rules.has(key) ? rules.get(key) : true) && Boolean(grant.group('where')));
      }
      continue;
    }
    if (py.strip(line) === '/') {    // the end of this entity: what follows is not its query
      inQuery = false;
      continue;
    }
    if (inQuery && views.has(current)) {
      for (const match of SOURCE.finditer(line)) {
        const entity = name(match.group('entity'));
        if (!views.get(current).includes(entity)) views.get(current).push(entity);
      }
    }
  }
  return [views, rules];
}

function findings(lines) {
  const [views, rules] = read(lines);
  const found = [];
  const ordered = py.sorted([...rules].map(([k, v]) => [...JSON.parse(k), v]), null);
  for (const [view, sources] of views) {
    for (const [role, entity, constrained] of ordered) {
      if (entity !== view || constrained) continue;
      // Only a constrained rule: the role sees its own rows. A role with no rule on the source
      // at all (a manager reading dashboard totals) is not row-scoped, so its view is fine.
      const hidden = sources.filter(source => source !== view && rules.get(keyOf(role, source)) === true);
      if (!hidden.length) continue;
      found.push(
        `[VIEW01] ${role} reads every row of the view ${view} with no XPath constraint, but sees ` +
        `only its own rows of ${hidden.join(', ')}: the view hands it every other ` +
        `customer's figures. Either constrain the rule (\`grant ${role} on ${view} (read *) where ` +
        `'[...]';\` over a column that identifies the signed-in user's rows), or \`revoke ${role} on ` +
        `${view};\` and let the page's data-source microflow read the view without entity access, ` +
        'filtered to the object the role may see (skill manage-security)');
    }
  }
  return found;
}

function main(argv) {
  let expect = 0;
  if (argv.length === 3 && argv[1] === '--expect' && /^\p{Nd}+$/u.test(argv[2])) {
    expect = Number(argv[2]);
    argv = argv.slice(0, 1);
  }
  if (argv.length !== 1) {
    process.stderr.write('VIEW01: a view entity that hands a row-scoped role every row of the data it summarises.\n' +
      '    node view_access.cjs <entities.mdl> [--expect <entities described>]\n');
    return 2;
  }
  // 2, not a crash's 1: the gate reads 1 as "findings".
  let out;
  try {
    const lines = py.splitlines(py.readText(argv[0]));
    // Entities were described and no head was recognised: not "no view hands out rows".
    if (expect > 0 && !lines.some(line => HEAD.match(line))) {
      process.stderr.write(`view_access.cjs could not run: ${expect} entities were described and none was ` +
        'recognised (a describe format it does not read)\n');
      return 2;
    }
    out = findings(lines);
  } catch (error) {
    const what = error.code === 'ENOENT' ? `FileNotFoundError: [Errno 2] No such file or directory: '${argv[0]}'`
      : `${error.name}: ${error.message}`;
    process.stderr.write(`view_access.cjs could not run: ${what}\n`);
    return 2;
  }
  for (const line of out) py.print(line);
  return out.length ? 1 : 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
module.exports = { HEAD, GRANT, SOURCE, read, findings, main };
