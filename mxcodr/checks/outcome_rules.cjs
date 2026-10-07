// OUTCOME01: every message the app can show a user is asserted by some test.
//
//     const { outcomes, untested, testCorpus } = require('./outcome_rules.cjs');
//     outcomes(documents) -> [{document, kind, text, words}]
//     untested(outcomes, corpus) -> the outcomes no test asserts
//
// A message is where a path through the app ends for the user: "Order saved", "Credit limit
// exceeded", "That order belongs to another customer". So the messages of a model are a list of its
// testable paths that needs no knowledge of the app, and a test that asserts one has walked that path.
// Read from the MDL source mxcli's catalog holds for each document (CATALOG.SOURCE):
//   show message <text> type <T> [objects [...]]        in a microflow or nanoflow
//   validation feedback $X/Attr message <text> [with (...)]
//   not null | unique | ... error message '<text>'       on an entity's attribute
//   a call passing text to a MESSAGE FLOW: a flow whose String parameter reaches one of the above,
//     directly or through another message flow -- found by what the flow does, never by its name.
// Text that is only placeholders, or variables filled at run time, cannot be matched and is skipped
// (counted, not reported). Matching ignores case and punctuation: a test asserts a message when it
// holds a run of the message's words -- MIN_RUN of them, or all of a shorter message -- outside a
// comment line. Written for Node after the port from Python, so plain RegExp.
'use strict';
const fs = require('fs');
const path = require('path');

const MIN_RUN = 4;

// Statements of one document's source, split at `;` outside quotes ('' is a quote inside a literal).
function statements(source) {
  const out = [];
  let current = '', quoted = false;
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    if (c === "'") {
      if (quoted && source[i + 1] === "'") { current += "''"; i++; continue; }
      quoted = !quoted;
    }
    if (c === ';' && !quoted) { if (current.trim()) out.push(current.trim()); current = ''; continue; }
    current += c;
  }
  if (current.trim()) out.push(current.trim());
  return out;
}

const literals = text => [...(text || '').matchAll(/'((?:[^']|'')*)'/g)].map(m => m[1].replace(/''/g, "'"));
const words = text => (text.replace(/\{\d+\}/g, ' ').toLowerCase().match(/[\p{L}\p{N}]+/gu) || []);
const variables = text => [...(text || '').replace(/'(?:[^']|'')*'/g, "''").matchAll(/\$(\w+)/g)].map(m => m[1]);

// A statement without the @position(...) and @caption '...' in front of it.
const withoutAnnotations = statement => statement.replace(/^(?:@\w+(?:\([^)]*\)|\s+'(?:[^']|'')*')\s*)+/, '');

// The parts of a message statement that carry its text: [template, ...arguments], or null.
function messageParts(statement) {
  const s = withoutAnnotations(statement);
  let m;
  if ((m = /^show\s+message\s+([\s\S]*?)\s+type\s+\w+([\s\S]*)$/i.exec(s))) {
    const objects = /objects\s*\[([\s\S]*)\]/i.exec(m[2]);
    return [m[1], objects ? objects[1] : ''];
  }
  if ((m = /^validation\s+feedback\s+\$[\w/.]+\s+message\s+([\s\S]*?)(?:\s+with\s*\(([\s\S]*)\))?$/i.exec(s))) {
    return [m[1], m[2] || ''];
  }
  return null;
}

// A call: {target, args: {Param: expression}}, or null.
function callOf(statement) {
  const m = /\bcall\s+(?:microflow|nanoflow)\s+([\w.]+)\s*\(([\s\S]*)\)\s*(?:on\s+error[\s\S]*)?$/i.exec(statement);
  if (!m) return null;
  const args = {};
  // Split the argument list at commas outside quotes and brackets.
  let depth = 0, quoted = false, current = '';
  const parts = [];
  for (const c of m[2]) {
    if (c === "'") quoted = !quoted;
    if (!quoted && '([{'.includes(c)) depth++;
    if (!quoted && ')]}'.includes(c)) depth--;
    if (c === ',' && !quoted && depth === 0) { parts.push(current); current = ''; continue; }
    current += c;
  }
  if (current.trim()) parts.push(current);
  for (const part of parts) {
    const a = /^\s*\$?(\w+)\s*=\s*([\s\S]+)$/.exec(part);
    if (a) args[a[1]] = a[2].trim();
  }
  return { target: m[1], args };
}

// What each flow's String parameters are and its body statements.
function parseFlows(documents) {
  const flows = new Map();
  for (const d of documents) {
    if (!/^(MICROFLOW|NANOFLOW)$/.test(d.ObjectType)) continue;
    const src = d.SourceText || '';
    const head = /\b(?:microflow|nanoflow)\s+[\w.]+\s*\(([^)]*)\)/i.exec(src);
    const stringParams = new Set();
    for (const p of (head ? head[1] : '').split(',')) {
      const m = /\$(\w+)\s*:\s*String\b/i.exec(p);
      if (m) stringParams.add(m[1]);
    }
    const body = /\bbegin\b([\s\S]*)\bend\s*;?/i.exec(src);
    flows.set(d.QualifiedName, { name: d.QualifiedName, module: d.ModuleName, stringParams, statements: statements(body ? body[1] : '') });
  }
  return flows;
}

// Variables a flow fills from an expression: {var: expression} (declare and set).
function assignments(flow) {
  const out = {};
  for (const s of flow.statements) {
    const m = /^(?:declare\s+\$(\w+)\s+\w+\s*=|set\s+\$(\w+)\s*=)\s*([\s\S]+)$/i.exec(s);
    if (m) { const v = m[1] || m[2]; out[v] = (out[v] ? out[v] + ' + ' : '') + m[3]; }
  }
  return out;
}

// Flows whose String parameter reaches a statement `isSink(statement)` says carries it, directly or
// through another such flow: {flow: Set of those parameters}. A fixpoint, since a flow may hand its
// text on to another one.
function forwarding(flows, isSink) {
  const found = new Map();
  let changed = true;
  while (changed) {
    changed = false;
    for (const flow of flows.values()) {
      if (!flow.stringParams.size) continue;
      const assigned = assignments(flow);
      // The parameter a variable's value comes from, followed through assignments.
      const reaches = v => {
        const seen = new Set(); const stack = [v];
        while (stack.length) {
          const x = stack.pop(); if (seen.has(x)) continue; seen.add(x);
          if (flow.stringParams.has(x)) return x;
          for (const y of variables(assigned[x] || '')) stack.push(y);
        }
        return null;
      };
      const mine = found.get(flow.name) || new Set();
      const before = mine.size;
      for (const s of flow.statements) {
        const sink = isSink(s);
        if (sink) for (const v of variables(sink)) { const p = reaches(v); if (p) mine.add(p); }
        const call = callOf(s);
        if (call && found.has(call.target)) {
          for (const param of found.get(call.target)) {
            for (const v of variables(call.args[param] || '')) { const p = reaches(v); if (p) mine.add(p); }
          }
        }
      }
      if (mine.size !== before) { found.set(flow.name, mine); changed = true; }
    }
  }
  return found;
}

// The flows that call `targets`, not counting those in `targets` themselves.
function callers(flows, targets) {
  const out = new Set();
  for (const flow of flows.values()) {
    if (targets.has(flow.name)) continue;
    if (flow.statements.some(s => { const c = callOf(s); return c && targets.has(c.target); })) out.add(flow.name);
  }
  return out;
}

// A message stored for a page to show (an app's own toast or notice list): text a flow writes into
// an attribute, when many flows hand it their text. One caller is a form saving a name; three or
// more are a notice the whole app raises.
const STORE_CALLERS = 3;
const storedText = s => {
  const m = /^(?:\$\w+\s*=\s*)?(?:create\s+[\w.]+|change\s+\$\w+)\s*\(([\s\S]*)\)\s*$/i.exec(s.replace(/^(?:@\w+(?:\([^)]*\)|\s+'(?:[^']|'')*')\s*)+/, ''));
  return m ? m[1] : null;
};

// Message flows: {flow: Set of its String parameters that reach a message the user sees}.
function messageFlows(flows) {
  const found = forwarding(flows, s => { const p = messageParts(s); return p ? p.join(' ') : null; });
  const stored = forwarding(flows, storedText);
  // Group the storing flows by the flow that finally writes the text, with the wrappers around it.
  const writers = [...stored.keys()].filter(name => flows.get(name).statements.some(s => storedText(s)));
  for (const writer of writers) {
    const group = new Set([writer]);
    let grew = true;
    while (grew) {
      grew = false;
      for (const name of stored.keys()) {
        if (group.has(name)) continue;
        if (flows.get(name).statements.some(s => { const c = callOf(s); return c && group.has(c.target); })) { group.add(name); grew = true; }
      }
    }
    if (callers(flows, group).size >= STORE_CALLERS) for (const name of group) found.set(name, new Set([...(found.get(name) || []), ...stored.get(name)]));
  }
  return found;
}

// The literal text of an expression, following the flow's own variables back to their literals.
function textOf(expression, assigned, seen = new Set()) {
  let pieces = literals(expression);
  for (const v of variables(expression)) {
    if (seen.has(v) || !assigned[v]) continue;
    seen.add(v);
    pieces = pieces.concat(textOf(assigned[v], assigned, seen));
  }
  return pieces;
}

// Every user-visible message of the given modules' documents.
// documents: [{QualifiedName, ModuleName, ObjectType, SourceText}]
function outcomes(documents, modules) {
  const own = new Set(modules);
  const flows = parseFlows(documents);
  const senders = messageFlows(flows);
  const out = [];
  const add = (document, kind, pieces) => {
    // A placeholder splits a text: '{1} saved. Available credit: {2}' is asserted around the values.
    const segments = pieces.flatMap(p => p.split(/\{\d+\}/)).map(words).filter(w => w.length);
    if (!segments.length) return;
    out.push({ document, kind, text: pieces.filter(p => words(p).length).join(' … '), pieces: segments });
  };
  for (const flow of flows.values()) {
    if (!own.has(flow.module)) continue;
    const assigned = assignments(flow);
    const params = senders.get(flow.name) || new Set();
    for (const s of flow.statements) {
      const parts = messageParts(s);
      if (parts) {
        // A message flow's own statement shows the text its callers pass: counted at the call.
        const fromParam = variables(parts.join(' ')).some(v => params.has(v));
        const pieces = textOf(parts.join(' + '), assigned);
        if (!fromParam || literals(parts.join(' ')).some(p => words(p).length > 1)) {
          add(flow.name, /^validation\s+feedback/i.test(withoutAnnotations(s)) ? 'validation' : 'message', pieces);
        }
        continue;
      }
      const call = callOf(s);
      if (call && senders.has(call.target)) {
        const pieces = [];
        for (const param of senders.get(call.target)) pieces.push(...textOf(call.args[param] || '', assigned));
        add(flow.name, 'message', pieces);
      }
    }
  }
  for (const d of documents) {
    if (d.ObjectType !== 'ENTITY' || !own.has(d.ModuleName)) continue;
    for (const m of (d.SourceText || '').matchAll(/\berror\s+message\s+'((?:[^']|'')*)'/gi)) {
      add(d.QualifiedName, 'validation rule', [m[1].replace(/''/g, "'")]);
    }
  }
  return out;
}

// The tests' words, with comment lines left out: a comment that quotes a message is not a test of it.
function testCorpus(files) {
  const kept = [];
  for (const [name, text] of files) {
    for (const line of text.split(/\r?\n/)) {
      const t = line.trim();
      if (/^(#|--|\/\/)/.test(t) && !t.startsWith('#!')) continue;
      kept.push(line);
    }
    kept.push('\n');
  }
  return ' ' + words(kept.join(' ')).join(' ') + ' ';
}

// Can a test match it at all: some piece of two words or more.
const matchable = o => o.pieces.some(p => p.length >= 2);

// The pieces worth matching: the longest ones, so two common words ("available credit") do not
// stand for a sentence when the message has a longer piece to show.
const telling = o => {
  const longest = Math.max(...o.pieces.map(p => p.length));
  return o.pieces.filter(p => p.length >= Math.min(3, longest) && p.length >= 2);
};

function asserted(outcome, corpus, minRun = MIN_RUN) {
  for (const piece of telling(outcome)) {
    const run = Math.min(minRun, piece.length);
    for (let i = 0; i + run <= piece.length; i++) {
      if (corpus.includes(' ' + piece.slice(i, i + run).join(' ') + ' ')) return true;
    }
  }
  return false;
}

function untested(list, corpus, minRun = MIN_RUN) {
  return list.filter(o => matchable(o) && !asserted(o, corpus, minRun));
}

// The tests the gate runs, tests/verify-*.test.sh: [[relative name, text]]. Microflow tests
// (*.test.mdl) are not among them -- the gate does not run them -- so a message written there walks
// nothing: an assertion nothing executes is not a test of the path (B2B, 2026-10-08).
function testFiles(appDir) {
  const dir = path.join(appDir, 'tests');
  let names = [];
  try { names = fs.readdirSync(dir).filter(n => /^verify-.*\.test\.sh$/.test(n)).sort(); } catch { /* none */ }
  return names.map(n => ['tests/' + n, fs.readFileSync(path.join(dir, n), 'utf8')]);
}

module.exports = { MIN_RUN, STORE_CALLERS, statements, messageParts, callOf, parseFlows, messageFlows, outcomes, testCorpus, testFiles, matchable, asserted, untested, words };
