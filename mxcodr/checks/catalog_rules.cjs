#!/usr/bin/env node
// The catalog step: rules answered by mxcli's catalog tables on a copy of the project. UI001 and
// SEC007 were the two mxcli lint rules that blocked DONE, ported one to one from their Starlark
// (.claude/lint-rules); the gate does not run mxcli lint itself:
//   UI001   a data grid filtered by hand -- inputs bound to a non-persistent helper entity in a
//           module whose grid has no column filter (ui001_handrolled_grid_filter.star)
//   SEC007  an entity readable by anonymous users with no XPath constraint (DIVD-2022-00019;
//           sec_unconstrained_anon_read.star)
//   STATUS01 a button whose flow always sets one status, and that stays on the page once the object
//           has it: a second click sets the same status again (a warning; the fix is a Visible: condition)
//   STARTUP01 the after-startup microflow returns false on a path: Mendix stops the app then, so a seed
//           that returns false once its rows exist boots once and fails every restart after
//   SEED01  a page the menu opens lists an entity from the database for a role that cannot create it,
//           and no after-startup seed creates it: the tests' rows are rolled back at DONE, so that role
//           signs in to an empty list
//   LINT01  mxcli's own lint advice: off unless the rulebook says warn or block, then
//           `mxcli lint --format json` runs here and its findings are listed at that level
//
// Usage: catalog_rules.cjs <app_dir> <Module>... [--mpr <copy.mpr>] [--no-refresh] [--levels json] [--except json]
// Prints `FAIL|WARN|PASS <summary>`, `  - [CODE] ...` blocking lines, `  ~ [CODE] ...` warnings.
// Exit 0 nothing blocking, 1 blocking findings, 2 the model could not be read.
'use strict';
const { spawnSync } = require('child_process');
const { mxcli, ModelReadError, binary, catalogArgs } = require('./mxcli_client.cjs');
const { readModel } = require('./security_rules.cjs');
const { levelArgs, levelOf } = require('./rulebook.cjs');

// The grid, and the filter widgets that belong inside its columns (the Starlark's constants).
const GRID_TYPES = new Set(['com.mendix.widget.web.datagrid.Datagrid']);
const FILTER_MARKERS = ['datagriddropdownfilter', 'datagriddatefilter', 'datagridtextfilter', 'datagridnumberfilter'];
const INPUT_TYPES = new Set(['Forms$CheckBox', 'Forms$DatePicker', 'Forms$TextBox', 'Forms$DropDown', 'Forms$RadioButtonGroup',
  'com.mendix.widget.web.combobox.Combobox']);
const MIN_INPUTS = 2;

const entityOfAttribute = ref => { const parts = String(ref || '').split('.'); return parts.length < 3 ? '' : parts.slice(0, -1).join('.'); };

// UI001: [{code, key, message}] -- one per module and helper entity, like the Starlark rule.
function handRolledGridFilter(widgets, entities) {
  const nonPersistent = new Set(entities.filter(e => /non[-_]?persistent/i.test(e.EntityType || e.Type || '')).map(e => e.QualifiedName));
  const grids = {}, filtersSeen = {}, helperInputs = {}, firstInput = {};
  for (const w of widgets) {
    const module = w.ModuleName;
    if (!module) continue;
    const type = w.WidgetType || '', lowered = type.toLowerCase();
    if (FILTER_MARKERS.some(m => lowered.includes(m))) filtersSeen[module] = true;
    if (GRID_TYPES.has(type)) { grids[module] = w; continue; }
    if (!INPUT_TYPES.has(type)) continue;
    const owner = entityOfAttribute(w.AttributeRef);
    if (!owner || !nonPersistent.has(owner)) continue;
    ((helperInputs[module] = helperInputs[module] || {})[owner] = helperInputs[module][owner] || []).push(w.Name);
    if (!firstInput[module + '|' + owner]) firstInput[module + '|' + owner] = w;
  }
  const out = [];
  for (const module of Object.keys(grids)) {
    if (filtersSeen[module]) continue;
    for (const [helper, names] of Object.entries(helperInputs[module] || {})) {
      if (names.length < MIN_INPUTS) continue;
      const w = firstInput[module + '|' + helper];
      out.push({ code: 'UI001', key: w.ContainerQualifiedName,
        message: `'${w.ContainerQualifiedName}' has ${names.length} hand-built filter input(s) bound to the non-persistent entity '${helper}' ` +
          `(${[...names].sort().slice(0, 4).join(', ')}), and data grid '${grids[module].Name}' in this module has no column filter. ` +
          'Put the filter in the column it belongs to and delete the helper entity, its apply microflow and the XPath that reads it: ' +
          'column colStatus (attribute: Status) { dropdownfilter fltStatus }, column colCreated (attribute: DateCreated) { datefilter fltCreated (FilterType: between) }, ' +
          'column colCustomer (attribute: Order_Customer/Name) { dropdownfilter fltCustomer (Association: Module.Order_Customer, datasource: database Module.Customer, CaptionAttribute: Name) }' });
    }
  }
  return out;
}

// SEC007: a READ rule with no XPath on a persistent entity, for a module role of the guest user role.
function anonymousUnconstrainedRead(model, entities) {
  const sec = model.security;
  if (!sec.guest || !sec.guestRole) return [];
  const anon = new Set(model.moduleRoles[sec.guestRole] || []);
  if (!anon.size) return [];
  const persistent = new Set(entities.filter(e => /^persistent$/i.test(e.EntityType || e.Type || '')).map(e => e.QualifiedName));
  const out = [], seen = new Set();
  for (const p of model.permissions) {
    if (p.ElementType !== 'ENTITY' || p.AccessType !== 'READ' || p.XPathConstraint || !anon.has(p.ModuleRoleName) || !persistent.has(p.ElementName)) continue;
    const key = p.ElementName + '|' + p.ModuleRoleName;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ code: 'SEC007', key: p.ElementName,
      message: `Entity '${p.ElementName}' is readable by anonymous users (via role '${p.ModuleRoleName}') with no XPath constraint — all rows exposed to unauthenticated users. ` +
        `(DIVD-2022-00019) Add an XPath constraint to the access rule for '${p.ModuleRoleName}', or remove the grant if this data should not be public.` });
  }
  return out;
}

// The text between the bracket at `open` and its partner (quotes respected), and the index after it.
function balanced(text, open) {
  const close = { '(': ')', '{': '}' }[text[open]];
  let depth = 0, quote = '';
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (quote) { if (c === quote) quote = ''; continue; }
    if (c === "'" || c === '"') { quote = c; continue; }
    if (c === text[open]) depth++;
    else if (c === close && --depth === 0) return { body: text.slice(open + 1, i), end: i + 1 };
  }
  return { body: text.slice(open + 1), end: text.length };
}

// `a = 1, b = f(x, y)` -> ['a = 1', 'b = f(x, y)']: commas outside brackets and quotes.
function topLevel(text) {
  const parts = [];
  let depth = 0, quote = '', from = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) { if (c === quote) quote = ''; continue; }
    if (c === "'" || c === '"') quote = c;
    else if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ',' && !depth) { parts.push(text.slice(from, i).trim()); from = i + 1; }
  }
  if (text.slice(from).trim()) parts.push(text.slice(from).trim());
  return parts;
}

// {param: {attr: value}} for a flow's parameters whose enumeration attribute the flow only ever sets
// to that one value: `change $Invoice (Status = Mod.InvoiceStatus.Sent)` and nothing else for it.
// A flow that sets two values (a button that walks through statuses) or a computed one is left out.
function singleStatusTargets(source, enumerations) {
  const header = /\b(?:microflow|nanoflow)\s+[\w.]+\s*\(/i.exec(source);
  if (!header) return {};
  const params = new Set();
  const head = balanced(source, header.index + header[0].length - 1);
  for (const m of head.body.matchAll(/\$(\w+)\s*:/g)) params.add(m[1]);
  const seen = {};
  const re = /\bchange\s+\$(\w+)\s*\(/gi;
  let m;
  while ((m = re.exec(source.slice(head.end)))) {
    if (!params.has(m[1])) continue;
    const at = head.end + m.index + m[0].length - 1;
    for (const part of topLevel(balanced(source, at).body)) {
      const a = /^(\w+)\s*=\s*([\s\S]+)$/.exec(part);
      if (!a) continue;
      const v = /^([\w]+\.[\w]+)\.(\w+)$/.exec(a[2].trim());
      const entry = ((seen[m[1]] = seen[m[1]] || {})[a[1]] = seen[m[1]][a[1]] || { values: new Set(), other: false });
      if (v && enumerations.has(v[1])) entry.values.add(a[2].trim()); else entry.other = true;
    }
  }
  const out = {};
  for (const [param, attrs] of Object.entries(seen)) {
    for (const [attr, e] of Object.entries(attrs)) {
      if (e.other || e.values.size !== 1) continue;
      (out[param] = out[param] || {})[attr] = [...e.values][0];
    }
  }
  return out;
}

// STATUS01: [{code, key, message}] -- sources: CATALOG.SOURCE rows of the app's own modules;
// enumerations: the qualified names of every enumeration.
function repeatStatusButtons(sources, enumerations) {
  const flows = {};
  for (const d of sources) if (d.ObjectType === 'MICROFLOW' || d.ObjectType === 'NANOFLOW') flows[d.QualifiedName] = singleStatusTargets(d.SourceText || '', enumerations);
  const out = [];
  for (const page of sources.filter(d => d.ObjectType === 'PAGE' || d.ObjectType === 'SNIPPET')) {
    const text = page.SourceText || '';
    const re = /\bactionbutton\s+(\w+)\s*\(/gi;
    let m;
    while ((m = re.exec(text))) {
      const body = balanced(text, m.index + m[0].length - 1).body;
      const call = /\bAction:\s*call\s+(?:microflow|nanoflow)\s+([\w.]+)\s*\(/i.exec(body);
      if (!call || !flows[call[1]]) continue;
      const args = topLevel(balanced(body, call.index + call[0].length - 1).body);
      const visible = (/\bVisible:\s*([\s\S]*?)(?:,\s*\w+\s*:|$)/i.exec(body) || [])[1] || '';
      if (/^\s*false\s*$/i.test(visible)) continue;
      for (const arg of args) {
        const p = /^(\w+)\s*=/.exec(arg);
        const targets = p && flows[call[1]][p[1]];
        if (!targets) continue;
        for (const [attr, value] of Object.entries(targets)) {
          if (new RegExp(`\\b${attr}\\b`).test(visible)) continue;
          out.push({ code: 'STATUS01', key: page.QualifiedName,
            message: `${m[1]} on ${page.QualifiedName} calls ${call[1]}, which always sets ${p[1]}/${attr} to ${value}, and the button ` +
              `stays on the page once ${attr} is ${value.split('.').pop()}: a second click sets the same status again. Hide it then -- ` +
              `fix this before DONE: alter page ${page.QualifiedName} { set Visible = [${attr} != ${value}] on ${m[1]} }; and put the same ` +
              `Visible: in the script that creates the page; let ${call[1]} check the status too (an older open page still reaches it), ` +
              `and make the test click it once and then see it gone (return {gone: !(await page.locator('.mx-name-${m[1]}').count())}). ` +
              'Leave it only when a second click must really do it again, and then say why in the final report' });
        }
      }
    }
  }
  return out;
}

// LINT01: mxcli lint's findings, each as one line, when the rulebook asks for them. The JSON (mxcli
// 0.25): {violations: [{ruleId, severity, message, module, document, documentType, suggestion}], summary}.
function lintFindings(appDir, mpr) {
  // The project's own ./mxcli, bounded like every other call (MDL_MXCLI_TIMEOUT).
  const timeout = parseFloat(process.env.MDL_MXCLI_TIMEOUT || '120');
  const result = spawnSync(binary(appDir), ['lint', '-p', mpr, '--format', 'json'], { cwd: appDir, encoding: 'utf8', timeout: timeout * 1000, maxBuffer: 1 << 28, windowsHide: true });
  return parseLint(result.stdout || '');
}
function parseLint(text) {
  const start = text.indexOf('{');
  if (start < 0) throw new ModelReadError('`mxcli lint --format json` printed no JSON');
  let parsed;
  try { parsed = JSON.parse(text.slice(start)); } catch { throw new ModelReadError('`mxcli lint --format json` printed no JSON'); }
  const list = Array.isArray(parsed) ? parsed : (parsed && parsed.violations) || [];
  return list.map(v => {
    const where = v.module ? `${v.module}.${v.document || ''}` : (v.document || '');
    return { code: 'LINT01', key: where, severity: String(v.severity || '').toLowerCase(),
      message: `[${v.ruleId || '?'}] ${v.message || ''}${where ? ` (at ${where})` : ''}${v.suggestion ? ` -- ${v.suggestion}` : ''}` };
  });
}

// STARTUP01: [{code, key, message}] when the after-startup microflow (DESCRIBE SETTINGS) returns false
// on some path. Mendix fails the start on false ("The after-startup-action failed with an exception or
// returned false"). A room-booking app's seed returned false when its rooms were already there: it
// passed DONE on the running app and failed every restart after (2026-10-13).
function startupReturnsFalse(settingsText, describeFlow) {
  const m = /AfterStartupMicroflow\s*[:=]\s*'([^']+)'/.exec(settingsText || '');
  if (!m) return [];
  const flow = m[1];
  const text = describeFlow(flow) || '';
  if (!/\breturns\s+Boolean\b/i.test(text) || !/\breturn\s+false\s*;/i.test(text)) return [];
  return [{ code: 'STARTUP01', key: flow,
    message: `the after-startup microflow ${flow} returns false on a path: Mendix stops the app when it does, so the app ` +
      'starts once and fails the next restart (a seed that returns false once its rows exist). Return true on every path that is ' +
      `not a real failure -- \`else return true;\` -- and keep it idempotent: alter microflow ${flow} or its script, then exec it again.` }];
}

// A qualified name as DESCRIBE writes it, quotes dropped: "Shop"."Order" -> Shop.Order.
const QNAME = '"?\\w+"?\\."?\\w+"?';
const unquote = name => String(name || '').replace(/"/g, '');

// SEED01: [{code, key, message}] -- one per entity that a page the menu opens (a menu item or a home
// page) lists from the database for a role that cannot create it -- no create access, no microflow it may
// run that creates one -- and that neither the after-startup microflow nor a microflow it calls creates.
// The gate rolls the tests' rows back at DONE (tests/db-snapshot.sh), so what such a role meets is the
// seed: an invoice-chasing app built with no seed handed over customer logins whose invoice lists were
// empty, and a customer cannot make an invoice (2026-10-14). A list the role fills itself (my bookings)
// is not judged. A created specialization counts for its generalization. Accounts (System.User) come
// from demo users and files from uploads, so those are not judged; a seed that calls a Java action, a
// REST service or an import may create anything, and then nothing is judged.
function listsWithoutSeed(settingsText, navigationText, sources, entities, permissions, modules) {
  const byName = {};
  for (const e of entities) byName[e.QualifiedName] = e;
  const lineage = name => {
    const out = [name];
    for (let e = byName[name], guard = 0; e && e.Generalization && guard < 20; e = byName[e.Generalization], guard++) out.push(e.Generalization);
    return out;
  };
  const source = {};
  for (const d of sources) source[d.QualifiedName] = d.SourceText || '';
  // What a microflow creates, with every microflow it calls; null when it calls out (Java, REST, an import).
  const createdBy = {};
  const creates = flow => {
    if (flow in createdBy) return createdBy[flow];
    createdBy[flow] = new Set();
    const text = source[flow] || '';
    if (/\bcall\s+(?:java\s+action|rest|web\s+service)\b|\bsend\s+rest\b|\bimport\s+(?:from|with)\b/i.test(text)) return (createdBy[flow] = null);
    const out = new Set();
    for (const m of text.matchAll(new RegExp(`\\bcreate\\s+(${QNAME})\\s*\\(`, 'gi'))) for (const a of lineage(unquote(m[1]))) out.add(a);
    // A workflow the seed starts creates rows through the microflows its activities name (`on created
    // microflow`, `call microflow`): an approval task list filled by the workflow is seeded (B2B, 2026-10-15).
    const callees = [...text.matchAll(new RegExp(`\\bcall\\s+(?:microflow|workflow)\\s+(${QNAME})`, 'gi'))].map(m => m[1]);
    if (/^\s*create\s+(?:or\s+modify\s+)?workflow\b/im.test(text)) {
      for (const m of text.matchAll(new RegExp(`\\bmicroflow\\s+(${QNAME})`, 'gi'))) callees.push(m[1]);
    }
    for (const m of callees.map(c => [null, c])) {
      const inner = creates(unquote(m[1]));
      if (inner === null) return (createdBy[flow] = null);
      for (const a of inner) out.add(a);
    }
    return (createdBy[flow] = out);
  };
  const viewers = {}, creators = {};
  const add = (map, key, role) => (map[key] = map[key] || new Set()).add(role);
  for (const p of permissions) {
    if (p.ElementType === 'PAGE' && p.AccessType === 'VIEW') add(viewers, p.ElementName, p.ModuleRoleName);
    else if (p.ElementType === 'ENTITY' && p.AccessType === 'CREATE') for (const a of lineage(p.ElementName)) add(creators, a, p.ModuleRoleName);
    else if (p.ElementType === 'MICROFLOW' && p.AccessType === 'EXECUTE') for (const a of creates(p.ElementName) || []) add(creators, a, p.ModuleRoleName);
  }
  // The pages, and the snippets they place, whose lists the person meets first: {entity: [page, role]}.
  const shown = new Set();
  for (const m of (navigationText || '').matchAll(new RegExp(`\\b(?:home\\s+page|show\\s+page|page)\\s+(${QNAME})`, 'gi'))) shown.add(unquote(m[1]));
  const listed = {};
  const visit = (doc, page, seen) => {
    if (seen.has(doc) || !(doc in source)) return;
    seen.add(doc);
    const text = source[doc];
    for (const m of text.matchAll(new RegExp(`\\b(?:datagrid|gallery|listview)\\s+\\w+\\s*\\([^{;]*?DataSource:\\s*database\\s+(?:from\\s+)?(${QNAME})`, 'gi'))) {
      const entity = unquote(m[1]);
      const e = byName[entity];
      if (entity in listed || !e || !modules.has(e.ModuleName) || !/^persistent$/i.test(e.EntityType || '') || String(e.IsExternal) === '1') continue;
      if (lineage(entity).some(a => a === 'System.User' || a === 'System.FileDocument')) continue;
      const reader = [...(viewers[page] || [])].sort().find(role => !(creators[entity] || new Set()).has(role));
      if (reader) listed[entity] = [page, reader];
    }
    for (const m of text.matchAll(new RegExp(`\\bSnippet:\\s*(${QNAME})`, 'gi'))) visit(unquote(m[1]), page, seen);
  };
  for (const page of [...shown].sort()) visit(page, page, new Set());
  if (!Object.keys(listed).length) return [];
  const startup = (/AfterStartupMicroflow\s*[:=]\s*'([^']+)'/.exec(settingsText || '') || [])[1] || '';
  const seeded = startup ? creates(startup) : new Set();
  if (seeded === null) return [];
  return Object.entries(listed).filter(([name]) => !seeded.has(name)).map(([name, [page, role]]) => ({ code: 'SEED01', key: name,
    message: `${page} lists ${name} from the database for ${role}, which cannot create one, and ` +
      `${startup ? `the after-startup microflow ${startup} never creates one` : 'the app has no after-startup microflow'}: the gate rolls the ` +
      'tests\' rows back at DONE, so that role signs in to an empty list. ' +
      (startup ? `Create a few realistic ${name.split('.').pop()} rows in ${startup} (or a microflow it calls)`
        : `Write a seed microflow that creates a few realistic ${name.split('.').pop()} rows, and set it: alter settings runtime ( AfterStartupMicroflow: '<Module>.ASU_Seed' )`) +
      ' -- only when none exist yet, linked to the demo users who should see them, returning true on every path. ' +
      `An app that really starts empty: say so in the final report; the person adds \`except: ${name}\` under ## Local in tests/rulebook/catalog/SEED01.md` }));
}

function main() {
  const { levels, excepts, rest: argv } = levelArgs(process.argv.slice(2));
  const args = catalogArgs(argv);
  if (!args) { process.stderr.write('usage: catalog_rules.cjs app_dir Module... [--mpr copy.mpr] [--no-refresh] [--levels json] [--except json]\n'); return 2; }
  const { appDir, mpr, refresh } = args;
  const modules = new Set(args.modules);
  if (!mpr) { process.stdout.write(`ERROR no .mpr in ${appDir}\n`); return 2; }
  const level = code => levelOf(levels, code, { LINT01: 'off', STATUS01: 'warn', SEED01: 'warn' }[code] || 'block');
  let found = [];
  try {
    if (refresh) mxcli(appDir, mpr, 'refresh catalog full source');
    const entities = mxcli(appDir, mpr, 'SELECT QualifiedName, ModuleName, EntityType, Generalization, IsExternal FROM CATALOG.ENTITIES', true);
    if (level('UI001') !== 'off') {
      const widgets = mxcli(appDir, mpr, 'SELECT Name, WidgetType, AttributeRef, ContainerQualifiedName, ContainerType, ModuleName FROM CATALOG.WIDGETS', true);
      found.push(...handRolledGridFilter(widgets.filter(w => modules.has(w.ModuleName)), entities));
    }
    if (level('SEC007') !== 'off') found.push(...anonymousUnconstrainedRead(readModel(appDir, mpr), entities.filter(e => modules.has(e.ModuleName))));
    if (level('STATUS01') !== 'off') {
      const sources = mxcli(appDir, mpr, "SELECT QualifiedName, ModuleName, ObjectType, SourceText FROM CATALOG.SOURCE WHERE ObjectType IN ('MICROFLOW', 'NANOFLOW', 'PAGE', 'SNIPPET')", true);
      const enumerations = new Set(mxcli(appDir, mpr, 'SELECT QualifiedName FROM CATALOG.ENUMERATIONS', true).map(e => e.QualifiedName));
      found.push(...repeatStatusButtons(sources.filter(d => modules.has(d.ModuleName)), enumerations));
    }
    if (level('STARTUP01') !== 'off') {
      found.push(...startupReturnsFalse(mxcli(appDir, mpr, 'DESCRIBE SETTINGS'), flow => mxcli(appDir, mpr, `DESCRIBE MICROFLOW ${flow}`)));
    }
    if (level('SEED01') !== 'off') {
      const sources = mxcli(appDir, mpr, "SELECT QualifiedName, ObjectType, SourceText FROM CATALOG.SOURCE WHERE ObjectType IN ('MICROFLOW', 'PAGE', 'SNIPPET', 'WORKFLOW')", true);
      const permissions = mxcli(appDir, mpr, "SELECT ModuleRoleName, ElementType, ElementName, AccessType FROM CATALOG.PERMISSIONS WHERE ElementType IN ('PAGE', 'ENTITY', 'MICROFLOW')", true);
      found.push(...listsWithoutSeed(mxcli(appDir, mpr, 'DESCRIBE SETTINGS'), mxcli(appDir, mpr, 'DESCRIBE NAVIGATION'), sources, entities, permissions, modules));
    }
    if (level('LINT01') !== 'off') found.push(...lintFindings(appDir, mpr));
  } catch (error) {
    if (!(error instanceof ModelReadError)) throw error;
    process.stdout.write(`ERROR could not read the model -- ${error.message}\n`);
    return 2;
  }
  found = found.filter(f => !(excepts[f.code] || []).includes(f.key || ''));
  // LINT01 at `warn` lists every lint finding as a warning; at `block` lint's own errors block.
  const blocking = found.filter(f => level(f.code) === 'block' && (f.code !== 'LINT01' || f.severity === 'error'));
  const warnings = found.filter(f => !blocking.includes(f) && level(f.code) !== 'info');
  const lines = [`${blocking.length ? 'FAIL' : warnings.length ? 'WARN' : 'PASS'}  ${blocking.length} catalog finding(s) block, ${warnings.length} warning(s)`];
  for (const f of blocking) lines.push(`  - [${f.code}] ${f.message}`);
  for (const f of warnings) lines.push(`  ~ [${f.code}] ${f.message}`);
  process.stdout.write(lines.join('\n') + '\n');
  return blocking.length ? 1 : 0;
}

if (require.main === module) process.exitCode = main();
module.exports = { handRolledGridFilter, anonymousUnconstrainedRead, parseLint, singleStatusTargets, repeatStatusButtons, startupReturnsFalse, listsWithoutSeed };
