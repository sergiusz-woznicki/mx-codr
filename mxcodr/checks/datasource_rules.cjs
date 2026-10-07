// DS01: a list widget fed by a microflow or nanoflow that only retrieves its rows.
//
//     const { dataSourceFindings } = require('./datasource_rules.cjs');
//     dataSourceFindings(flowLines, pageText) -> [[code, message, line]]
//
// A data grid, list view or gallery on a `database` source lets the database page, sort and filter:
// the grid asks for 20 rows, and Data Grid 2's column filters run on the server. On a microflow or
// nanoflow source the flow returns the whole list, the client gets every row and pages it itself,
// and the screen slows as the table grows. A `database` source also applies the entity's access
// rules (a data source microflow does not, SCOPE01). Over 34 local apps 67 list widgets took their
// rows from a flow; most of those flows did nothing but a retrieve, a sort and a return.
//
// Convertible -- and so a finding -- is a flow whose body is only:
//   retrieve $X from [database] M.E [where [...]] [sort by ...];   one database retrieve, or
//   retrieve $X from $P/M.Assoc;  (one or more association steps)   from a parameter
//   $Y = sort($X, Attr asc|desc);                                   optional
//   return $Y;
// Anything else (a loop, a call, a create or change, an aggregate, two lists joined, `first`, a
// REST or Java call) cannot be an XPath, and is left alone. Nanoflows are held to the same rule.
// Written for Node after the port from Python, so plain RegExp.
'use strict';

const LIST_WIDGETS = /^\s*(datagrid|listview|gallery|templategrid)\s+("[^"]*"|[\w.]+)/i;
const FLOW_HEAD = /^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:microflow|nanoflow)\s+([\w.]+)/i;
const PAGE_HEAD = /^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:page|snippet)\s+([\w.]+)/i;

// {flow: body statements, one string each (annotations, comments and blank lines dropped)}.
function flowBodies(flowLines) {
  const bodies = new Map();
  let name = '', inBody = false, statements = [], current = '';
  const flush = () => { if (name) bodies.set(name, statements); };
  for (const raw of flowLines) {
    const head = FLOW_HEAD.exec(raw);
    if (head) { flush(); name = head[1]; inBody = false; statements = []; current = ''; continue; }
    if (!name) continue;
    const line = raw.trim();
    if (!inBody) { if (/^begin\b/i.test(line)) inBody = true; continue; }
    if (!line || line.startsWith('@') || line.startsWith('--') || line.startsWith('//')) continue;
    if (/^end\s*;?$/i.test(line)) { inBody = false; continue; }
    current += (current ? ' ' : '') + line;
    if (line.endsWith(';')) { statements.push(current.replace(/;$/, '').trim()); current = ''; }
  }
  flush();
  return bodies;
}

// The flow's rows as a database source, or null when the flow does anything but retrieve them.
// {entity, path: [assoc...] from parameter, param, where, sort} -- what the suggestion is built from.
function asDatabaseSource(statements) {
  if (!statements || !statements.length) return null;
  const vars = new Map();   // $name -> {param, path, entity, where, sort}
  let returned = null;
  for (const s of statements) {
    let m;
    if ((m = /^retrieve\s+\$(\w+)\s+from\s+(?:database\s+)?([\w.]+)(?:\s+where\s+(\[.*?\]|.*?))?(?:\s+sort\s+by\s+(.+?))?$/i.exec(s)) && !/\$/.test(m[2].split(/\s/)[0])) {
      if (/\b(first|limit)\b/i.test(s)) return null;
      let where = (m[3] || '').trim();
      if (where && !where.startsWith('[')) where = `[${where}]`;
      vars.set(m[1], { entity: m[2], path: [], param: null, where, sort: (m[4] || '').trim() });
    } else if ((m = /^retrieve\s+\$(\w+)\s+from\s+\$(\w+)\/([\w./]+)$/i.exec(s))) {
      const from = vars.get(m[2]);
      if (from && from.entity) return null;        // an association from a database result: a join, not one query
      const steps = m[3].split('/').filter(x => /\./.test(x));
      vars.set(m[1], { entity: '', param: from ? from.param : m[2], path: [...(from ? from.path : []), ...steps], where: '', sort: '' });
    } else if ((m = /^\$(\w+)\s*=\s*sort\s*\(\s*\$(\w+)\s*,\s*(.+)\)$/i.exec(s)) || (m = /^\$(\w+)\s*=\s*sort\s+\$(\w+)\s+by\s+(.+)$/i.exec(s))) {
      const from = vars.get(m[2]);
      if (!from) return null;
      vars.set(m[1], { ...from, sort: m[3].trim() });
    } else if ((m = /^return\s+\$(\w+)$/i.exec(s))) {
      returned = vars.get(m[1]) || null;
    } else {
      return null;   // anything else: a call, a loop, a change, an aggregate ...
    }
  }
  return returned;
}

// The argument the widget passes to each flow parameter: {param: '$currentObject' | '$PageParam' | ...}.
function argumentsOf(call) {
  const out = {};
  for (const m of (call || '').matchAll(/(\w+)\s*=\s*(\$[\w/.]+)/g)) out[m[1]] = m[2];
  return out;
}

// The XPath value for a flow parameter: the enclosing object, or the page parameter it was given.
function valueFor(param, args) {
  const arg = args[param];
  if (!arg || arg === '$currentObject') return "'[%CurrentObject%]'";
  return arg;
}

function suggestionFor(source, args, rowEntity) {
  if (!source) return '';
  const sort = source.sort ? ` sort by ${source.sort.replace(/,\s*/g, ', ')}` : '';
  if (source.entity) {
    const where = source.where.replace(/\$(\w+)/g, (all, p) => (p.toLowerCase() === 'currentuser' ? all : valueFor(p, args)));
    return `DataSource: database ${source.entity}${where ? ' where ' + where : ''}${sort}`;
  }
  const value = valueFor(source.param, args);
  if (source.path.length === 1 && rowEntity) {
    return `DataSource: database ${rowEntity} where [${source.path[0]} = ${value}]${sort}`;
  }
  // Several association steps: the XPath walks them back from the rows to the parameter.
  return `DataSource: database ${rowEntity || '<the row entity>'} where [<the path from it back over ${source.path.join(', ')}> = ${value}]${sort}` +
    ' -- check the path with ./mxcli check';
}

function dataSourceFindings(flowLines, pageText) {
  const bodies = flowBodies(flowLines);
  const out = [];
  const lines = (pageText || '').split(/\r?\n/);
  let page = '';
  lines.forEach((line, i) => {
    const head = PAGE_HEAD.exec(line);
    if (head) { page = head[1]; return; }
    const widget = LIST_WIDGETS.exec(line);
    if (!widget) return;
    // The widget's properties may run over the next lines; the context comment follows them.
    let props = line, j = i + 1;
    while (j < lines.length && !/[{]\s*$/.test(props) && j < i + 12) { props += ' ' + lines[j].trim(); j++; }
    const src = /DataSource:\s*(microflow|nanoflow)\s+([\w.]+)\s*(\(([^)]*)\))?/i.exec(props);
    if (!src) return;
    const source = asDatabaseSource(bodies.get(src[2]));
    if (!source) return;
    let rowEntity = '';
    for (let k = i + 1; k < Math.min(lines.length, j + 3); k++) {
      const ctx = /--\s*Context:\s*\$currentObject\s*\(([\w.]+)\)/.exec(lines[k]);
      if (ctx) { rowEntity = ctx[1].includes('.') ? ctx[1] : ''; break; }
    }
    const suggestion = suggestionFor(source, argumentsOf(src[4]), rowEntity || source.entity);
    out.push(['DS01', `${page}: ${widget[1].toLowerCase()} ${widget[2]} gets its rows from ${src[1].toLowerCase()} ${src[2]}, which only` +
      ' retrieves them: the client receives every row and pages them itself, so the screen slows as the table grows,' +
      ' and Data Grid 2\'s column filters cannot run on the server. A database source lets the database page, sort and' +
      ` filter, and applies the entity's access rules: \`${suggestion}\`. Then drop ${src[2]} if nothing else calls it.`, i + 1]);
  });
  return out;
}

module.exports = { dataSourceFindings, asDatabaseSource, flowBodies };
