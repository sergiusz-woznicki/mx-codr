// SCOPE02 / SCOPE03: the build stays inside the approved requirements.
//
// Once the requirements are approved (a person's yes, or at `requirements: assume` the agent's own
// promotion) they ARE the scope. Two runs of one two-sentence prompt built 6 and 9 flows, 6 and 8 pages
// (invoice-chase iq3a/iq3b, 2026-10-24): the second added a KPI home page with four helper entities, a
// log entity and edit flows. This file is the trace that points them out: which documents serve no
// approved requirement. It reuses what the harness already has and invents no new link:
//
//   - an anchor of a requirement (`brain capture ... -a @Module.Doc`, docs/brain/plan/ and the queue);
//   - a test file that names a requirement (`# requirement: <id>`, REQ02) puts its `# covers:` documents
//     in scope: they are what that requirement is built with;
//   - what a traced document reaches (CATALOG.REFS: the entity a page shows, the microflow a button
//     calls, the page a flow opens, a snippet it places) is covered by the thing it serves.
//
// Support is never flagged: snippets, DS_/SUB_/ASU_/VAL_ flows, enumerations, the home and login pages,
// seed flows, and the signed-in-user entity a snippet shows. "No requirements recorded" is no scope
// check at all (an app built before the brain existed).
//
// SCOPE02 (precheck, block): a new page or ACT_ microflow of an exec that nothing traces.
// SCOPE03 (paths, warn): the same on the finished model, plus helper entities (non-persistent or view
// entities that only hold computed values) that no approved requirement names or needs.
'use strict';
const fs = require('fs');
const path = require('path');
const { readPlan, stagedEntries, requirementsMode } = require('./requirement_rules.cjs');

// The requirements that were approved: the plan's, and what waits in the queue for the person's yes
// (an open question is an assumption, not a requirement). [{id, text, anchors}]
function approvedRequirements(appDir) {
  const out = readPlan(appDir).requirements.map(r => ({ id: r.id, text: r.text, anchors: r.anchors || [] }));
  for (const e of stagedEntries(appDir)) {
    if (e.open || e.kind !== 'requirement') continue;
    out.push({ id: String(e.id), text: String(e.title || ''), anchors: Array.isArray(e.anchors) ? e.anchors : [] });
  }
  return out;
}

// `@Invoicing.Invoice`, `@Mod.Invoicing.Invoice`, `@Invoicing.Invoice.Number` -> Module.Doc names.
function anchorNames(requirements) {
  const names = new Set();
  for (const r of requirements) {
    for (const a of r.anchors) {
      const parts = String(a).replace(/^@/, '').split('.').filter(Boolean);
      if (parts.length >= 2) { names.add(parts.slice(0, 2).join('.')); names.add(parts.slice(-2).join('.')); }
    }
  }
  return names;
}

// The names on the `# covers:` lines of a test (and the `#` lines under it holding only more names).
const NAME_LIST = String.raw`[\w.]+\.\w+(?:(?:\s*,\s*|\s+)[\w.]+\.\w+)*\s*,?`;
const COVERS_RE = new RegExp(String.raw`^\s*#\s*covers\s*:\s*(.+(?:\n\s*#\s*` + NAME_LIST + String.raw`\s*$)*)`, 'gim');
function coveredNames(raw) {
  const names = [];
  for (const m of raw.matchAll(COVERS_RE)) names.push(...(m[1].replace(/^\s*#/gm, ' ').match(/[\w]+\.[\w]+/g) || []));
  return names;
}

// The documents the tests that name an approved requirement cover: [name...]. testFiles: [[name, text]].
function coveredByRequirementTests(testFiles, requirements) {
  const known = new Set(requirements.map(r => r.id));
  const out = new Set();
  for (const [, raw] of testFiles) {
    const ids = [];
    for (const m of raw.matchAll(/^\s*#\s*requirements?\s*:\s*(.+)$/gim)) ids.push(...(m[1].match(/[0-9a-f]{6,}/g) || []));
    if (ids.some(id => known.has(id))) for (const n of coveredNames(raw)) out.add(n);
  }
  return out;
}

// Documents that serve the app and no single requirement: never flagged.
const SUPPORT_PAGE = /home|landing|login|welcome|notfound|forgot|password|account|(?:^|_)users?(?:_|$)/i;
const SUPPORT_FLOW = /seed|demo|startup|login|logout|signin|signout|sign_in|sign_out/i;
const leaf = name => String(name).split('.').pop();
function isSupport(kind, name) {
  if (kind === 'page') return SUPPORT_PAGE.test(leaf(name));
  if (kind === 'microflow') return SUPPORT_FLOW.test(leaf(name));
  return false;
}

// Everything the documents `from` reach through the references [{SourceName, TargetName}], themselves included.
function reach(refs, from) {
  const next = new Map();
  for (const r of refs) {
    if (!r.SourceName || !r.TargetName || r.SourceName === r.TargetName) continue;
    if (!next.has(r.SourceName)) next.set(r.SourceName, []);
    next.get(r.SourceName).push(r.TargetName);
  }
  const seen = new Set(from), queue = [...from];
  while (queue.length) for (const t of next.get(queue.pop()) || []) if (!seen.has(t)) { seen.add(t); queue.push(t); }
  return seen;
}

// Whether the scope check applies to this app at all: requirements are recorded and not switched off.
function applies(appDir) {
  if (requirementsMode(appDir) === 'off') return null;
  const requirements = approvedRequirements(appDir);
  return requirements.length ? requirements : null;
}

// SCOPE02. fresh: [[kind, name]] the exec creates (pages, ACT_ microflows). The ones nothing traces.
function unplannedNew(appDir, testFiles, fresh) {
  const requirements = applies(appDir);
  if (!requirements) return [];
  const traced = new Set([...anchorNames(requirements), ...coveredByRequirementTests(testFiles, requirements)]);
  return fresh.filter(([kind, name]) => !isSupport(kind, name) && !traced.has(name));
}

// SCOPE03 findings on the finished model: [{code, key, version, message}].
// model.sources: [{QualifiedName, ModuleName, ObjectType, SourceText}], model.refs: [{SourceName, TargetName, RefKind}].
function scopeFindings(appDir, model, testFiles, modules, hash) {
  const requirements = applies(appDir);
  if (!requirements) return [];
  const own = new Set(modules);
  const direct = anchorNames(requirements);
  const roots = new Set([...direct, ...coveredByRequirementTests(testFiles, requirements)]);
  const refs = model.refs || [];
  const served = reach(refs, roots);
  const homes = new Set(refs.filter(r => r.RefKind === 'home_page').map(r => r.TargetName));
  const out = [];
  const advice = 'tie it to an approved requirement it genuinely serves (the test that checks that requirement names it on its `# covers:` line), ' +
    'or leave it out and list the idea under "to add next" in your final report';
  for (const d of model.sources) {
    if (!own.has(d.ModuleName)) continue;
    const name = d.QualifiedName;
    const kind = d.ObjectType === 'PAGE' ? 'page' : d.ObjectType === 'MICROFLOW' && leaf(name).startsWith('ACT_') ? 'microflow' : '';
    if (!kind || isSupport(kind, name) || homes.has(name) || served.has(name)) continue;
    out.push({ code: 'SCOPE03', key: name, version: hash(d.SourceText),
      message: `${kind} ${name} serves no approved requirement: no requirement names it, and no test that names a requirement covers it -- ${advice}` });
  }
  // Helper entities: a non-persistent or view entity only holds computed values (totals, a summary, the
  // user's name for a snippet). A summary is a feature the request has to ask for: planned when a
  // requirement names the entity, or the page or flow that needs it; support when a snippet shows it.
  const fromSnippets = reach(refs, new Set(model.sources.filter(d => d.ObjectType === 'SNIPPET').map(d => d.QualifiedName)));
  const fromAnchored = reach(refs, direct);
  for (const d of model.sources) {
    if (!own.has(d.ModuleName) || d.ObjectType !== 'ENTITY') continue;
    if (!/create\s+(?:or\s+(?:modify|replace)\s+)?(?:non-persistent|view)\s+entity/i.test(d.SourceText || '')) continue;
    const name = d.QualifiedName;
    if (direct.has(name) || fromSnippets.has(name) || fromAnchored.has(name)) continue;
    out.push({ code: 'SCOPE03', key: name, version: hash(d.SourceText),
      message: `${name} is a helper entity for computed values (totals, a summary, a dashboard) and no approved requirement names it or the page that needs it -- ${advice}` });
  }
  return out;
}

module.exports = { approvedRequirements, anchorNames, coveredNames, coveredByRequirementTests, isSupport, reach, applies, unplannedNew, scopeFindings };
