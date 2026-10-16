#!/usr/bin/env node
// FOLDER01: every document of the app's own modules sits in <business folder>/<kind>, where the
// kind folder says what it holds:
//   UI   pages, snippets, layouts, building blocks, page templates
//   FNC  microflows and nanoflows
//   ENV  everything else: enumerations, constants, Java and JavaScript actions, JSON structures,
//        mappings, REST and OData services, workflows, scheduled events, image collections, ...
// e.g. Products/UI/Product_Edit, Products/FNC/ACT_Product_AddTags, Products/ENV/JA_GenerateImage,
// and what the whole module shares in _Shared/<kind>. A business folder may nest (Orders/Approval/UI).
// The person asked for it (2026-10-08): business folders held thirty documents of every kind in one
// list, and constants and enumerations lay at module root. Entities and associations live in the
// domain model and have no folder.
//
// Usage: check_folders.cjs <app_dir> <Module>... [--mpr <copy.mpr>] [--no-refresh]
// Prints PASS/FAIL, `  - [FOLDER01] ...` per document, then `move: <statement>` lines.
// Exit 0 none, 1 findings, 2 the model could not be read.
'use strict';
const { mxcli, ModelReadError, catalogArgs } = require('./mxcli_client.cjs');
const { levelArgs, levelOf } = require('./rulebook.cjs');

const KIND = {
  PAGE: 'UI', SNIPPET: 'UI', LAYOUT: 'UI', BUILDING_BLOCK: 'UI', PAGE_TEMPLATE: 'UI',
  MICROFLOW: 'FNC', NANOFLOW: 'FNC',
};
// Not documents in a folder: the domain model's own, and what a module carries without a place.
// A business event is a message inside its service document, not a document of its own.
const NO_FOLDER = new Set(['ENTITY', 'ASSOCIATION', 'MODULE', 'MENU', 'JAR_DEPENDENCY', 'NAVIGATION_PROFILE', 'BUSINESS_EVENT']);
const KINDS = ['UI', 'FNC', 'ENV'];
// mxcli 0.27 reports Studio Pro's names in CATALOG.OBJECTS (mendixlabs/mxcli#1395); a query on the old
// value finds nothing, so the old ones (0.26, a cached catalog) are read as the new.
const RENAMED = { ODATA_SERVICE: 'PUBLISHED_ODATA_SERVICE', ODATA_CLIENT: 'CONSUMED_ODATA_SERVICE', REST_CLIENT: 'CONSUMED_REST_SERVICE', QUEUE: 'TASK_QUEUE' };
const typeOf = o => RENAMED[o.ObjectType] || o.ObjectType;
// Where the catalog leaves the folder empty, DESCRIBE may print it.
const DESCRIBED_FOLDER = { PUBLISHED_ODATA_SERVICE: 'published odata service', BUSINESS_EVENT_SERVICE: 'business event service' };
// mxcli 0.26 moves a business event service into a folder, but neither the catalog nor DESCRIBE says
// which: the rule could never pass, and a session dropped the service to reach DONE (B2B, 2026-10-14).
// Such a document is not judged until mxcli can read where it is.
const UNREADABLE_FOLDER = new Set(['BUSINESS_EVENT_SERVICE']);
const kindOf = type => KIND[type] || 'ENV';
// How `move` spells each document type (mxcli syntax move).
const spelled = type => (RENAMED[type] || type).toLowerCase().replace(/_/g, ' ');

const words = text => (String(text).replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().match(/[a-z0-9]+/g) || []);
const stem = w => (w.endsWith('ies') ? w.slice(0, -3) + 'y' : w.endsWith('s') && !w.endsWith('ss') ? w.slice(0, -1) : w);

// A root document's business folder: the module's folder whose name its own name uses
// (ENUM_OrderStatus -> Orders, ApprovalThreshold -> Approval); else _Shared.
function guessFolder(name, businessFolders) {
  const mine = words(name.split('.').pop()).map(stem);
  for (const folder of businessFolders) {
    const theirs = words(folder).map(stem).filter(w => w.length > 2);
    if (theirs.length && theirs.every(w => mine.includes(w))) return folder;
  }
  return '_Shared';
}

// One finding per misplaced document: {name, type, folder, target, message}.
function findings(objects, modules) {
  objects = objects.map(o => ({ ...o, ObjectType: typeOf(o) }));
  const own = new Set(modules);
  const out = [];
  // The business folders each module already has: the top segment of its documents' folders.
  const folders = {};
  for (const o of objects) {
    const top = String(o.Folder || '').replace(/^\/+/, '').split('/')[0];
    if (top && !KINDS.includes(top) && !top.startsWith('_')) (folders[o.ModuleName] = folders[o.ModuleName] || new Set()).add(top);
  }
  for (const o of objects) {
    if (!own.has(o.ModuleName) || NO_FOLDER.has(o.ObjectType) || o.unreadable) continue;
    const want = kindOf(o.ObjectType);
    const folder = String(o.Folder || '').replace(/^\/+|\/+$/g, '');
    const segments = folder ? folder.split('/') : [];
    const last = segments[segments.length - 1];
    const business = KINDS.includes(last) ? segments.slice(0, -1) : segments;
    const misplacedKind = business.find(s => KINDS.includes(s));
    let target, why;
    if (!folder) {
      target = `${guessFolder(o.QualifiedName, [...(folders[o.ModuleName] || [])].sort())}/${want}`;
      why = 'sits at module root';
    } else if (misplacedKind) {
      target = business.filter(s => !KINDS.includes(s)).concat(want).join('/') || `_Shared/${want}`;
      why = `is in '${folder}', with a kind folder inside the business path`;
    } else if (!business.length) {
      target = `_Shared/${want}`;
      why = `is in '${folder}', a kind folder with no business folder above it`;
    } else if (last === want) {
      continue;
    } else if (KINDS.includes(last)) {
      target = business.concat(want).join('/');
      why = `is in '${folder}', but a ${spelled(o.ObjectType)} belongs in ${want}`;
    } else {
      target = business.concat(want).join('/');
      why = `is in '${folder}' with no ${want} folder`;
    }
    out.push({
      name: o.QualifiedName, type: o.ObjectType, folder, target,
      message: `${spelled(o.ObjectType)} ${o.QualifiedName} ${why}: each business folder holds UI (pages, snippets), ` +
        `FNC (microflows, nanoflows) and ENV (everything else) -- move it to '${target}'` +
        (!folder ? ' or to the business folder that uses it' : ''),
    });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

const moveStatement = f => `move ${spelled(f.type)} ${f.name} to folder '${f.target}';`;

const USAGE = 'usage: check_folders.cjs app_dir Module... [--mpr copy.mpr] [--no-refresh]';

function main() {
  // --levels: the rulebook's level for FOLDER01 (block, warn, info, off); --except names documents
  // the person leaves where they are.
  const { levels, excepts, rest: argv } = levelArgs(process.argv.slice(2));
  const level = levelOf(levels, 'FOLDER01', 'block');
  const left = new Set(excepts.FOLDER01 || []);
  if (argv.includes('-h') || argv.includes('--help')) { process.stdout.write(USAGE + '\n'); return 0; }
  const args = catalogArgs(argv);
  if (!args) { process.stderr.write(USAGE + '\n'); return 2; }
  const { appDir, modules, mpr, refresh } = args;
  if (!mpr) { process.stdout.write(`ERROR no .mpr in ${appDir}\n`); return 2; }
  let objects;
  try {
    if (refresh) mxcli(appDir, mpr, 'refresh catalog full');
    objects = mxcli(appDir, mpr, 'SELECT QualifiedName, ModuleName, ObjectType, Folder FROM CATALOG.OBJECTS', true);
    for (const o of objects) o.ObjectType = typeOf(o);
  } catch (error) {
    if (!(error instanceof ModelReadError)) throw error;
    process.stdout.write(`ERROR could not read the model -- ${error.message}\n`);
    return 2;
  }
  if (!objects.length) { process.stdout.write('ERROR could not read the model -- the catalog lists no document\n'); return 2; }
  // mxcli 0.25's catalog records no folder for a published OData service (CATALOG.OBJECTS says ''
  // after a move that DESCRIBE shows took effect): its folder is read from DESCRIBE instead.
  const own = new Set(modules);
  for (const o of objects) {
    if (!(o.ObjectType in DESCRIBED_FOLDER) || o.Folder || !own.has(o.ModuleName)) continue;
    try {
      const text = mxcli(appDir, mpr, `describe ${DESCRIBED_FOLDER[o.ObjectType]} ${o.QualifiedName}`);
      const m = /\bfolder\s+'((?:[^']|'')*)'/i.exec(text);
      if (m) o.Folder = m[1].replace(/''/g, "'");
      else if (UNREADABLE_FOLDER.has(o.ObjectType)) o.unreadable = true;
    } catch { if (UNREADABLE_FOLDER.has(o.ObjectType)) o.unreadable = true; }
  }
  const found = level === 'off' ? [] : findings(objects, modules).filter(f => !left.has(f.name));
  if (!found.length) { process.stdout.write('PASS  every document is in <business folder>/UI, FNC or ENV\n'); return 0; }
  const lines = [`${level === 'block' ? 'FAIL' : 'WARN'}  ${found.length} document(s) outside <business folder>/UI, FNC or ENV`];
  if (level !== 'info') for (const f of found) lines.push(`  ${level === 'block' ? '-' : '~'} [FOLDER01] ${f.message}`);
  for (const f of found) lines.push(`move: ${moveStatement(f)}`);
  process.stdout.write(lines.join('\n') + '\n');
  return 1;
}

if (require.main === module) process.exitCode = main();
module.exports = { RENAMED, KIND, NO_FOLDER, UNREADABLE_FOLDER, DESCRIBED_FOLDER, kindOf, guessFolder, findings, moveStatement };
