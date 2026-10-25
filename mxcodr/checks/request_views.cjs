'use strict';
// What the request (docs/brain/requests/*.md) names, held against the screens. Two catalog-step rules:
//
//   FIELD01  a field the request lists for an entity ("Line: product, quantity, unitPriceNet, netValue") is
//            bound on no page or snippet that shows that entity. A B2B run kept the copied unit price in the
//            database and showed each line as "name x qty, net, gross": the person could not see the price
//            the order was placed at (b2b-orders hb4, 2026-10-25).
//   OVERVIEW01 an entity a role of the request sees, views, lists or manages ("Agent: sees all tickets",
//            "Agent: sees everything") has a list of it on a page that role reaches from the navigation --
//            its home page or a menu item. "All" or "everything" asks for an overview of every row: a list
//            whose data source is not tied to an object the page was given. The same run had no list of
//            invoices or products for the role that "sees everything"; a run without the harness had both.
//
// Matching is by name only, so it stays generic: a request word matches an entity or an attribute when
// they are the same letters once case, spaces and underscores are gone ("unit price net" = UnitPriceNet,
// "order number" = Order + Number); a list head matches the longest entity name it starts with
// ("OrderLineItem" -> OrderLine). A line counts as a field list only with three items or more, two of
// which name attributes, so prose is left alone. Nothing here judges a field shown on no screen at all,
// or an entity without a page: those are OVERVIEW01's, when a role asks to see them.

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

// FIELD01: [{code, key, message}].
function unshownFields(requests, entities, attributes, sources, modules, associations = []) {
  const own = entities.filter(e => modules.has(e.ModuleName) && /^persistent$/i.test(e.EntityType || '')).map(e => e.QualifiedName);
  const attrs = attributes.filter(a => own.includes(a.EntityQualifiedName) && !SKIP_TYPES.test(a.DataType || ''));
  const units = Object.values(screenBindings(sources.filter(d => modules.has(d.ModuleName)), associations));
  const out = [], said = new Set();
  for (const list of fieldLists(requests)) {
    const head = list.head ? entityFor(list.head, own) : null;
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

const VIEW_VERBS = /\b(?:sees?|seeing|views?|viewing|lists?|listing|brows(?:e|es|ing)|manag(?:e|es|ing)|filters?|searche?s?|tracks?|overview|widzi|przegl[aą]da|zarz[aą]dza|sieht|verwaltet)\b/i;
const EVERYTHING = /\b(?:sees?|views?|access(?:es)?\s+to|widzi|sieht)\s+(?:everything|all\s+(?:data|records|of\s+it)|wszystko|alles)\b/i;

// The first view verb of a clause, not a noun: "a dropdown list of the customers" and "their own view" name none.
const NOUN_BEFORE = /\b(?:a|an|the|this|that|its|their|your|own|dropdown|drop-down|price|pick|select|order|to-do|todo)\s*$/i;
function verbIn(clause) {
  const re = new RegExp(VIEW_VERBS.source, 'gi');
  for (const m of clause.matchAll(re)) if (!NOUN_BEFORE.test(clause.slice(0, m.index))) return m;
  return null;
}

// "never sees", "cannot view", "no access to": a view the role must not have.
const NEGATION = /\b(?:never|not|no|cannot|can't|cant|nobody|without|nie|nicht|kein\w*)\b/i;
// What a verb takes: the words up to the first preposition, possessives dropped. "see today's bookings for
// all rooms" asks for bookings; "other customers' invoices" names invoices. "A list of" keeps its "of".
function objectOf(text) {
  const words = String(text).replace(/\b\w+(?:'s|s')(?=\s|$)/gi, ' ').replace(/\b\w+['’]s\b/gi, ' ').split(/\s+/).filter(Boolean);
  const out = [];
  for (const w of words) {
    const bare = w.toLowerCase().replace(/[^a-ząćęłńóśźż]/g, '');
    if (/^(?:for|in|from|with|by|per|at|on|within|across|inside|under|about|to|into|z|dla|w|na|f[uü]r|im|mit|von)$/.test(bare)) break;
    if (bare === 'of' && !/^(?:list|lists|overview|table|grid|history|all|each|any|every)$/i.test((out[out.length - 1] || '').replace(/[^a-z]/gi, ''))) break;
    out.push(w);
  }
  return out.join(' ');
}

// The entities a clause names, longest name first: "order lines" is OrderLine, not Order.
function entitiesNamed(clause, entities) {
  const text = ' ' + clause.toLowerCase().replace(/[^a-z0-9ąćęłńóśźż]+/g, ' ') + ' ';
  const found = [];
  let rest = text;
  const byLength = [...entities].sort((a, b) => shortName(b).length - shortName(a).length);
  for (const e of byLength) {
    const words = shortName(e).replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[\s_]+/);
    const last = words.pop();
    const forms = plural(last).map(f => ' ' + [...words, f].join(' ') + ' ');
    const hit = forms.find(f => rest.includes(f));
    if (!hit) continue;
    const all = new RegExp(`\\b(?:all|every|each|wszystk\\w*|alle)\\s+(?:the\\s+|of\\s+the\\s+)?${hit.trim().replace(/\s+/g, '\\s+')}\\b`).test(text);
    found.push({ entity: e, all });
    rest = rest.split(hit).join(' ');
  }
  return found;
}

// [{role, entity, all, file, quote}] -- what each role of the request is to see.
function roleViews(requests, roleNames, topLevel, entities) {
  const out = [];
  const roleOf = word => roleNames.find(r => plural(norm(r)).includes(norm(word)));
  for (const { file, line } of requestLines(requests)) {
    const lead = /^([A-Za-z][A-Za-z ]{0,30}?)\s*[:–—-]\s+(.*)$/.exec(line);
    const sentences = [];
    if (lead && roleOf(lead[1])) sentences.push([roleOf(lead[1]), lead[2]]);
    else {
      for (const s of line.split(/(?<=[.;!?])\s+/)) {
        const m = /^(?:the\s+|an?\s+|each\s+|every\s+)?([A-Za-z]+)\b(.*)$/i.exec(s.trim());
        if (m && roleOf(m[1]) && verbIn(m[2].split(/[,;—–(]/)[0])) sentences.push([roleOf(m[1]), m[2]]);
      }
    }
    for (const [role, text] of sentences) {
      if (EVERYTHING.test(text)) for (const e of topLevel) out.push({ role, entity: e, all: true, file, quote: line });
      for (const clause of text.split(/[,;.—–()]/)) {
        const verb = verbIn(clause);
        if (!verb) continue;
        if (NEGATION.test(clause.slice(0, verb.index))) continue;
        for (const { entity, all } of entitiesNamed(objectOf(clause.slice(verb.index + verb[0].length)), entities)) out.push({ role, entity, all, file, quote: line });
      }
    }
  }
  return out;
}

// The pages each user role reaches from the navigation: its home page (the default one when it has
// none of its own) and the menu items it may open, a menu microflow's `show page` included.
function navigationPages(navigationText, sources, permissions, roleMappings, roleNames) {
  const text = String(navigationText || '');
  const source = {};
  for (const d of sources) source[d.QualifiedName] = d.SourceText || '';
  const shownBy = flow => [...String(source[flow] || '').matchAll(new RegExp(`\\bshow\\s+page\\s+(${QNAME})`, 'gi'))].map(m => unquote(m[1]));
  const homes = {}, defaults = [], menu = [];
  for (const m of text.matchAll(new RegExp(`\\bhome\\s+(page|microflow)\\s+(${QNAME})(?:\\s+for\\s+("?[\\w]+"?))?`, 'gi'))) {
    const pages = m[1].toLowerCase() === 'page' ? [unquote(m[2])] : shownBy(unquote(m[2]));
    if (m[3]) (homes[unquote(m[3])] = homes[unquote(m[3])] || []).push(...pages); else defaults.push(...pages);
  }
  for (const m of text.matchAll(new RegExp(`\\bmenu\\s+item\\b[^\\n]*?\\b(show\\s+page|call\\s+microflow)\\s+(${QNAME})`, 'gi'))) {
    if (/^show/i.test(m[1])) menu.push(unquote(m[2])); else menu.push(...shownBy(unquote(m[2])));
  }
  const viewers = {};
  for (const p of permissions) if (p.ElementType === 'PAGE' && p.AccessType === 'VIEW') (viewers[p.ElementName] = viewers[p.ElementName] || new Set()).add(p.ModuleRoleName);
  const out = {};
  for (const role of roleNames) {
    const moduleRoles = new Set(roleMappings.filter(r => r.UserRoleName === role).map(r => r.ModuleRoleName));
    const may = page => !viewers[page] || !moduleRoles.size || [...viewers[page]].some(r => moduleRoles.has(r));
    out[role] = new Set([...(homes[role] || defaults), ...menu].filter(may));
  }
  return out;
}

// A data source's own text: up to the comma or the bracket that ends it, brackets and quotes kept whole.
function dataSourceText(text, from) {
  let depth = 0, i = from;
  for (; i < text.length; i++) {
    const c = text[i];
    if (c === "'") { i = text.indexOf("'", i + 1); if (i < 0) return text.slice(from); continue; }
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) { if (depth === 0) break; depth--; }
    else if ((c === ',' || c === '\n') && depth === 0) break;
  }
  return text.slice(from, i).trim();
}

// The lists a page or snippet holds, with the snippets it places: [{entity, overview}]. An overview lists
// every row the role may read: a database source tied to no object of the page, or a flow without arguments.
function listsOn(doc, source, flowReturns, associations = {}, seen = new Set()) {
  if (seen.has(doc) || !(doc in source)) return [];
  seen.add(doc);
  const text = source[doc];
  const out = [];
  for (const m of text.matchAll(/\b(?:datagrid|gallery|listview|combobox)\s+[\w"]+\s*\(([^{;]*?)DataSource:\s*/gi)) {
    const ds = dataSourceText(text, m.index + m[0].length);
    let d;
    if ((d = new RegExp(`^database\\s+(?:from\\s+)?(${QNAME})(.*)$`, 'i').exec(ds))) out.push({ entity: unquote(d[1]), overview: !/\[%CurrentObject%\]|\$/.test(d[2]) });
    else if ((d = new RegExp(`^\\$\\w+/(${QNAME})`).exec(ds)) && associations[unquote(d[1])]) {
      const a = associations[unquote(d[1])];
      out.push({ entity: a.ToEntity, overview: false }, { entity: a.FromEntity, overview: false });
    } else if ((d = new RegExp(`^microflow\\s+(${QNAME})\\s*(\\(([^)]*)\\))?`, 'i').exec(ds)) && flowReturns[unquote(d[1])]) {
      out.push({ entity: flowReturns[unquote(d[1])], overview: !(d[3] || '').trim() });
    }
  }
  for (const m of text.matchAll(new RegExp(`\\bSnippet:\\s*(${QNAME})`, 'g'))) out.push(...listsOn(unquote(m[1]), source, flowReturns, associations, seen));
  return out;
}

// OVERVIEW01: [{code, key, message}].
function missingOverviews(requests, entities, sources, modules, navigationText, permissions, roleMappings, associationRows = []) {
  const associations = associationMap(associationRows);
  const own = entities.filter(e => modules.has(e.ModuleName) && /^persistent$/i.test(e.EntityType || '')).map(e => e.QualifiedName);
  const roleNames = [...new Set(roleMappings.map(r => r.UserRoleName))];
  if (!own.length || !roleNames.length) return [];
  // The entities the request's data model describes, less the parts of another ("lines: OrderLine[]").
  const lists = fieldLists(requests);
  const parts = new Set(lists.flatMap(l => l.items.map(i => i.type).filter(Boolean)).map(t => entityFor(t, own)).filter(Boolean));
  const topLevel = [...new Set(lists.map(l => (l.head ? entityFor(l.head, own) : null)).filter(e => e && !parts.has(e)))];
  const wanted = roleViews(requests, roleNames, topLevel, own);
  if (!wanted.length) return [];
  const source = {}, flowReturns = {};
  for (const d of sources) {
    source[d.QualifiedName] = d.SourceText || '';
    const r = new RegExp(`\\breturns\\s+list\\s+of\\s+(${QNAME})`, 'i').exec(d.SourceText || '');
    if (d.ObjectType === 'MICROFLOW' && r) flowReturns[d.QualifiedName] = unquote(r[1]);
  }
  const reach = navigationPages(navigationText, sources, permissions, roleMappings, roleNames);
  const out = [], said = new Set();
  for (const w of wanted) {
    const key = `${w.role}:${w.entity}`;
    if (said.has(key)) continue;
    const lists = [...(reach[w.role] || [])].flatMap(page => listsOn(page, source, flowReturns, associations).map(l => ({ ...l, page })));
    const ofIt = lists.filter(l => l.entity === w.entity);
    if (ofIt.some(l => !w.all || l.overview)) continue;
    said.add(key);
    const name = shortName(w.entity);
    const quote = w.quote.length > 90 ? w.quote.slice(0, 87) + '...' : w.quote;
    out.push({ code: 'OVERVIEW01', key: w.entity, message: `the request has ${w.role} see ${w.all ? 'all ' : ''}${name} rows ("${quote}", ${w.file}), ` +
      `and no page ${w.role} reaches from the navigation (its home page, a menu item) ${ofIt.length ? `lists every ${name}: ${[...new Set(ofIt.map(l => l.page))].join(', ')} lists only the ones of an object it was given` : `lists ${name}`}. ` +
      `Add an overview page: a data grid with DataSource: database from ${w.entity}, its columns the fields the request names, a grant view on page to ${w.role}'s module role, ` +
      `and a menu item for it (alter navigation ... insert before 'Log out'); assert its rows in a test signed in as ${w.role}. ` +
      `When the request means something else here: say so in the final report; the person adds \`except: ${w.entity}\` under ## Local in tests/rulebook/catalog/OVERVIEW01.md` });
  }
  return out;
}

module.exports = { fieldLists, entityFor, attributesFor, screenBindings, unshownFields, roleViews, entitiesNamed, navigationPages, listsOn, missingOverviews };
