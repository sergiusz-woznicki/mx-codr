'use strict';
// FIELD01, catalog step: the request (docs/brain/requests/*.md) lists the fields of an entity ("Line: product,
// quantity, unitPriceNet, netValue") and asks for a view of it ("the full list of line items", "a table of their
// invoices", "the ticket details"); each listed field is then bound on a page or snippet that shows that entity.
// A B2B run kept the copied unit price on each order line and showed the lines as "name x qty, net, gross": the
// person never saw the price the order was placed at (b2b-orders hb4, 2026-10-25). An entity the request asks no
// view of, or that no page shows, is not judged: the rule never asks for a page the request did not name.
//
// Matching is by name only, so it stays generic: a request word matches an entity or an attribute when
// they are the same letters once case, spaces and underscores are gone ("unit price net" = UnitPriceNet,
// "order number" = Order + Number); a list head matches the longest entity name it starts with
// ("OrderLineItem" -> OrderLine). A line counts as a field list only with three items or more, two of
// which name attributes, so prose is left alone.

const QNAME = '"?\\w+"?\\."?\\w+"?';
const unquote = name => String(name || '').replace(/"/g, '');
const norm = text => String(text || '').toLowerCase().replace(/[^a-z0-9]/g, '');
const shortName = qualified => unquote(qualified).split('.').pop();
const plural = word => [word, word + 's', word + 'es', word.replace(/y$/, 'ies')];

// The request's own text: headings out, one entry per line, bullets and numbering stripped.
function requestLines(requests) {
  const out = [];
  for (const [file, text] of requests) {
    for (const raw of String(text).split('\n')) {
      if (/^\s*#/.test(raw)) continue;
      const line = raw.replace(/^\s*(?:[-*•]|\d+[.)])\s*/, '').trim();
      if (line) out.push({ file, line });
    }
  }
  return out;
}

// Splits at `sep` outside (), [] and {}.
function splitTop(text, sep) {
  const out = [];
  let depth = 0, start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth = Math.max(0, depth - 1);
    else if (c === sep && depth === 0) { out.push(text.slice(start, i)); start = i + 1; }
  }
  out.push(text.slice(start));
  return out.map(s => s.trim()).filter(Boolean);
}

// One field of a list: its name (before any bracket or colon), the names inside its first bracket
// ("address (street, city, postal code)"), and the type after a colon ("lines: OrderLine[]").
function parseItem(text) {
  const item = text.replace(/^and\s+/i, '').replace(/[.;]+$/, '').trim();
  let depth = 0, cut = item.length;
  for (let i = 0; i < item.length; i++) {
    if (depth === 0 && '([{:'.includes(item[i])) { cut = i; break; }
  }
  const name = item.slice(0, cut).trim();
  const group = /[([{]([^()[\]{}]*)[)\]}]/.exec(item);
  const inner = group ? splitTop(group[1], ',').map(s => s.replace(/:.*$/, '').trim()).filter(s => /^[A-Za-z][\w ]{0,40}$/.test(s)) : [];
  const type = (/:\s*([A-Za-z]\w*)\s*\[\]/.exec(item) || /\blist\s+of\s+([A-Za-z]\w*)/i.exec(item) || [])[1] || '';
  return { name, inner, type };
}

// [{file, line, head, items}] -- the lines that read as "Head: field, field (...), field".
function fieldLists(requests) {
  const out = [];
  for (const { file, line } of requestLines(requests)) {
    let head = '', rest = line;
    const colon = (() => {
      let depth = 0;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if ('([{'.includes(c)) depth++;
        else if (')]}'.includes(c)) depth = Math.max(0, depth - 1);
        else if (c === ':' && depth === 0) return i;
      }
      return -1;
    })();
    if (colon > 0) {
      const before = line.slice(0, colon).trim();
      if (/^[A-Za-z][A-Za-z0-9_ ]{0,40}$/.test(before) && before.split(/\s+/).length <= 3) { head = before; rest = line.slice(colon + 1); }
    }
    const items = splitTop(rest, ',').map(parseItem).filter(i => i.name && i.name.split(/\s+/).length <= 4 && /^[A-Za-z][\w ]*$/.test(i.name));
    if (items.length >= 3) out.push({ file, line, head, items });
  }
  return out;
}

// The own persistent entity a request word names: exact, else the longest entity name the word starts
// with (OrderLineItem -> OrderLine), else one that starts with the word.
function entityFor(word, entities) {
  const n = norm(word);
  if (!n) return null;
  const singular = n.replace(/(ies)$/, 'y').replace(/s$/, '');
  let best = entities.find(e => [n, singular].includes(norm(shortName(e))));
  if (best) return best;
  const prefixed = entities.filter(e => n.startsWith(norm(shortName(e))) && norm(shortName(e)).length >= 3)
    .sort((a, b) => shortName(b).length - shortName(a).length);
  return prefixed[0] || null;
}

// The attributes ([qualified entity, attribute]) a field word names, in the head's entity first.
function attributesFor(word, headEntity, attributes, entities) {
  const n = norm(word);
  if (!n || n === 'id') return [];
  const matches = (entity, attr) => {
    const a = norm(attr), e = norm(shortName(entity));
    return n === a || n === e + a;
  };
  const own = new Set(entities);
  if (headEntity) {
    const inHead = attributes.filter(a => a.EntityQualifiedName === headEntity && matches(headEntity, a.Name));
    if (inHead.length) return inHead.map(a => [a.EntityQualifiedName, a.Name]);
  }
  return attributes.filter(a => own.has(a.EntityQualifiedName) && matches(a.EntityQualifiedName, a.Name)).map(a => [a.EntityQualifiedName, a.Name]);
}

// Per page or snippet: the entities it shows (a context or a data source) and the attributes it binds,
// by context entity (`E.A`) and by name alone (a path `Assoc/A`, a caption attribute). The catalog keeps
// a document's source on one line, DESCRIBE on many: read as tokens, quoted text skipped, braces counted.
const TOKENS = new RegExp([
  "('(?:[^']|'')*')",
  '--\\s*Context:\\s*\\$currentObject\\s*\\(([^)]+)\\)(?:,\\s*\\$(\\w+)\\s*\\(selection\\))?',
  `\\bDataSource:\\s*database\\s+(?:from\\s+)?(${QNAME})`,
  `\\bSnippet:\\s*(${QNAME})`,
  '\\bAttribute:\\s*([\\w"./]+)',
  '\\bCaptionAttribute:\\s*(\\w+)',
  "\\bContentParams:\\s*\\(((?:[^()']|'(?:[^']|'')*'|\\((?:[^()']|'(?:[^']|'')*')*\\))*)\\)",
  '(\\{)', '(\\})'].join('|'), 'g');
// A context names an entity, an association (the end that is not the enclosing object), a page or snippet
// parameter (`(Customer)` for `$Customer: Mod.Customer`) or the list a data view follows (its selection).
function contextEntity(name, enclosing, names, associations) {
  if (names[name]) return names[name];
  const assoc = associations[name];
  if (assoc) return assoc.ToEntity === enclosing ? assoc.FromEntity : assoc.ToEntity;
  return name.includes('.') ? name : '';
}
function associationMap(associations) {
  const out = {};
  for (const a of associations || []) out[a.QualifiedName] = a;
  return out;
}
function screenBindings(sources, associationRows) {
  const associations = associationMap(associationRows);
  const units = {};
  for (const doc of sources) {
    if (!/^(PAGE|SNIPPET)$/.test(doc.ObjectType)) continue;
    const unit = { entities: new Set(), bound: new Set(), names: new Set(), snippets: new Set() };
    const stack = [], selections = {};
    const params = /\bParams:\s*\(([^)]*)\)/.exec(String(doc.SourceText || ''));
    if (params) for (const m of params[1].matchAll(new RegExp(`\\$(\\w+)\\s*:\\s*(${QNAME})`, 'g'))) selections[m[1]] = unquote(m[2]);
    let depth = 0;
    const here = () => (stack.length ? stack[stack.length - 1][1] : '');
    const bind = attr => { unit.names.add(attr); if (here()) unit.bound.add(`${here()}.${attr}`); };
    for (const m of String(doc.SourceText || '').matchAll(TOKENS)) {
      if (m[1]) continue;
      if (m[2]) {
        const entity = contextEntity(unquote(m[2].trim()), here(), selections, associations);
        if (m[3] && entity) selections[m[3]] = entity;
        if (entity) { stack.push([depth, entity]); unit.entities.add(entity); }
      } else if (m[4]) { /* a picker's or a list's source: the list shows it through its own context */ }
      else if (m[5]) unit.snippets.add(unquote(m[5]));
      else if (m[6]) {
        const value = unquote(m[6]);
        if (value.includes('/')) unit.names.add(value.split('/').pop());
        else if (!value.includes('.')) bind(value);
      } else if (m[7]) unit.names.add(m[7]);
      else if (m[8] !== undefined) {
        const params = m[8].replace(/'(?:[^']|'')*'/g, "''");
        for (const p of params.matchAll(/\$currentObject\/(\w+)/g)) bind(p[1]);
        for (const p of params.matchAll(/(?<![$\w/])(\w+)\/(\w+)/g)) unit.names.add(p[2]);
        for (const p of params.matchAll(/\}\s*=\s*"?(\w+)\b"?(?!\s*[/(.]|\s+(?!format\b)\w)/g)) bind(p[1]);
      } else if (m[9]) depth++;
      else if (m[10]) {
        depth--;
        while (stack.length && stack[stack.length - 1][0] > depth) stack.pop();
      }
    }
    units[doc.QualifiedName] = unit;
  }
  // A snippet's bindings count for the pages that place it.
  for (const unit of Object.values(units)) {
    const seen = new Set();
    const visit = name => {
      if (seen.has(name) || !units[name]) return;
      seen.add(name);
      for (const e of units[name].entities) unit.entities.add(e);
      for (const b of units[name].bound) unit.bound.add(b);
      for (const n of units[name].names) unit.names.add(n);
      for (const s of units[name].snippets) visit(s);
    };
    for (const s of [...unit.snippets]) visit(s);
  }
  return units;
}

const SKIP_TYPES = /^(HashString|Binary)$/i;
// Words in a field's brackets that say its type or a rule, not a field of its own: "price (number, net)".
const TYPE_WORDS = /^(?:string|text|number|integer|int|long|decimal|float|boolean|bool|date|datetime|time|currency|money|enum|enumeration|unique|default|optional|required|mandatory|net|gross|calculated)$/i;

// The words a request uses for a view of rows or of one row.
const VIEWS = '(?:list|lists|table|tables|grid|overview|history|timeline|details?|columns?)';
const VIEW_WORDS = new RegExp(`\\b${VIEWS}\\b`, 'i');
// Does the request ask for a view of this entity? "list of line items", "table of their invoices", "order
// details", "status history": the head word or the entity's name (its last two words, or one when it has one).
// A picker is no view: "a dropdown list of the customers".
function viewAsked(headWord, entity, requests) {
  const split = w => String(w).replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[\s_]+/).filter(Boolean);
  const forms = new Set();
  for (const words of [split(headWord), split(shortName(entity))]) {
    for (let i = 0; i < words.length; i++) {
      const tail = words.slice(i);
      if (tail.length < Math.min(2, words.length)) continue;
      for (const last of plural(tail[tail.length - 1])) forms.add([...tail.slice(0, -1), last].join(' '));
    }
  }
  // A bracket or a colon ends the phrase: "a table of line items (product name, ...)" is no view of products.
  const text = ' ' + requests.map(([, t]) => t).join(' ').toLowerCase().replace(/[([{:;.,]/g, ' | ').replace(/[^a-z0-9|]+/g, ' ') + ' ';
  return [...forms].some(f => new RegExp(`(?<!\\b(?:drop ?down|select|pick|choose)\\s)\\b${VIEWS}\\s+of\\s+(?:\\w+\\s+){0,3}?${f}\\b|\\b${f}\\s+${VIEWS}\\b`).test(text));
}

// FIELD01: [{code, key, message}].
function unshownFields(requests, entities, attributes, sources, modules, associations = []) {
  const own = entities.filter(e => modules.has(e.ModuleName) && /^persistent$/i.test(e.EntityType || '')).map(e => e.QualifiedName);
  const attrs = attributes.filter(a => own.includes(a.EntityQualifiedName) && !SKIP_TYPES.test(a.DataType || ''));
  const units = Object.values(screenBindings(sources.filter(d => modules.has(d.ModuleName)), associations));
  const out = [], said = new Set();
  for (const list of fieldLists(requests)) {
    const head = list.head ? entityFor(list.head, own) : null;
    // Only a view the request asks for: of the head's entity somewhere in it, or, for a list with no head,
    // the line itself ("A table with columns: number, subject, priority").
    if (list.head ? !(head && viewAsked(list.head, head, requests)) : !VIEW_WORDS.test(list.line)) continue;
    const fields = [];
    for (const item of list.items) {
      const found = attributesFor(item.name, head, attrs, own);
      if (found.length) fields.push([item.name, found]);
      else if (head) for (const sub of item.inner.filter(w => !TYPE_WORDS.test(w))) {
        const inner = attributesFor(sub, head, attrs, own).filter(([e]) => e === head);
        if (inner.length) fields.push([sub, inner]);
      }
    }
    if (fields.length < 2) continue;
    for (const [word, candidates] of fields) {
      const shows = units.filter(u => candidates.some(([e]) => u.entities.has(e)));
      if (!shows.length) continue;
      if (shows.some(u => candidates.some(([e, a]) => u.bound.has(`${e}.${a}`) || u.names.has(a)))) continue;
      const [entity, attr] = candidates.find(([e]) => shows.some(u => u.entities.has(e))) || candidates[0];
      const key = `${entity}.${attr}`;
      if (said.has(key)) continue;
      said.add(key);
      const quote = list.line.length > 70 ? list.line.slice(0, 67) + '...' : list.line;
      out.push({ code: 'FIELD01', key, message: `the request lists ${word}${list.head ? ` for ${list.head}` : ''} ("${quote}", ${list.file}), ` +
        `and no page or snippet that shows ${entity} binds ${attr}: the person cannot see it. Put it where ${entity} is shown -- a column ` +
        `of its list (column (Attribute: ${attr}, Caption: '...')) or a read-only field of its detail -- and assert it in that page's test. ` +
        `A field the person agreed to keep off the screens: say so in the final report; the person adds \`except: ${key}\` under ## Local in tests/rulebook/catalog/FIELD01.md` });
    }
  }
  return out;
}

module.exports = { fieldLists, entityFor, attributesFor, screenBindings, viewAsked, unshownFields };
