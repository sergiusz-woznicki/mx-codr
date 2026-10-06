// EVENT01-04 and ERR01: entity event handlers and error handlers that fail without a sound.
//
//     const { eventFindings } = require('./event_rules.cjs');
//     eventFindings(flowLines, entityText, pageText) -> [[code, message, line]]
//
// <flowLines> is DESCRIBE MICROFLOW/NANOFLOW output, <entityText> DESCRIBE ENTITY output for the
// project's own entities, <pageText> DESCRIBE PAGE output; check_mdl.cjs passes them with
// --entities / --pages. An event handler runs inside every commit (create, delete) of its entity,
// in the same transaction, and nothing in the microflow that commits shows it. mx check and the
// lint rules see none of these; the first two break the app, the other three hide a failure.
//
//   EVENT01 FAIL  a commit handler commits the object it was called for, with events: the commit
//                 runs the handler again -- a loop that crashes at runtime
//   EVENT02 FAIL  a before handler without `raise error` can return false: the commit is skipped,
//                 with no message and no trace
//   EVENT03 WARN  `... without events` on an entity with a commit handler: what the handler does
//                 (a default, a check) does not happen
//   EVENT04 WARN  a page saves (Save changes) an entity whose before-commit handler raises an error:
//                 the user gets "An error has occurred" instead of a message at the field
//   ERR01   WARN  an error handler that does nothing anyone sees: no log, no raise, no message,
//                 no return (`on error continue` is mxcli's CONV014)
//
// One level deep: a handler that commits through a microflow it calls is not followed.
// Written for Node after the port from Python, so plain RegExp.
'use strict';

const HANDLER = /^\s*on\s+(before|after)\s+(create|commit|delete|rollback)\s+call\s+([\w.]+)\s*\(([^)]*)\)\s*(raise\s+error)?/i;
const ENTITY_HEAD = /^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:persistent\s+|non-persistent\s+)?entity\s+([\w.]+)/i;
const FLOW_HEAD = /^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:microflow|nanoflow)\s+([\w.]+)/i;
const PAGE_HEAD = /^\s*create\s+(?:or\s+(?:modify|replace)\s+)?page\s+([\w.]+)/i;
const PARAM = /\$(\w+)\s*:\s*([\w.]+)/g;

// {entity: [{moment, event, flow, raises, line}]} from the entities' describe text.
function handlersOf(entityText) {
  const found = new Map();
  let entity = '';
  for (const line of entityText.split(/\r?\n/)) {
    const head = ENTITY_HEAD.exec(line);
    if (head) { entity = head[1]; continue; }
    const h = HANDLER.exec(line);
    if (!h || !entity) continue;
    if (!found.has(entity)) found.set(entity, []);
    found.get(entity).push({ moment: h[1].toLowerCase(), event: h[2].toLowerCase(), flow: h[3], raises: Boolean(h[5]) });
  }
  return found;
}

// {name: {start (1-based line), lines}} for every flow in the describe text.
function flowsOf(lines) {
  const flows = new Map();
  let current = null;
  lines.forEach((line, index) => {
    const head = FLOW_HEAD.exec(line);
    if (head) { current = { name: head[1], start: index + 1, lines: [] }; flows.set(head[1], current); }
    if (current) current.lines.push(line);
  });
  return flows;
}

// The flow's parameters as {name: type}, from its header (up to `begin`).
function paramsOf(flow) {
  const header = [];
  for (const line of flow.lines) {
    if (/^\s*begin\b/i.test(line)) break;
    header.push(line);
  }
  return Object.fromEntries([...header.join(' ').matchAll(PARAM)].map(m => [m[1], m[2]]));
}

// [line number, text] of each body line matching <re>.
function where(flow, re) {
  const hits = [];
  // Quoted text is not code: `change $Order (Note = 'commit later')` commits nothing.
  flow.lines.forEach((line, i) => { if (re.test(line.replace(/'(?:[^']|'')*'/g, "''"))) hits.push([flow.start + i, line.trim()]); });
  return hits;
}

// The type of each variable a flow names: parameters, `$X = create E`, `retrieve $X from E`.
function typesOf(flow) {
  const types = paramsOf(flow);
  const text = flow.lines.join('\n');
  for (const m of text.matchAll(/\$(\w+)\s*=\s*create\s+([\w.]+)/gi)) types[m[1]] = m[2];
  for (const m of text.matchAll(/retrieve\s+\$(\w+)\s+from\s+(?:database\s+)?([\w.]+)/gi)) types[m[1]] = m[2];
  return types;
}

// True when a before handler's flow can return false: `return false`, an expression, or a
// variable that is declared or set to something other than true.
function canReturnFalse(flow) {
  const body = flow.lines.join('\n');
  if (/\breturn\s+false\s*;/i.test(body)) return true;
  for (const m of body.matchAll(/\breturn\s+([^;]+);/gi)) {
    const value = m[1].trim();
    if (/^true$/i.test(value)) continue;
    const variable = /^\$(\w+)$/.exec(value);
    if (!variable) return true;
    const name = variable[1];
    const assigned = [...body.matchAll(new RegExp(String.raw`(?:declare\s+\$${name}\s+\w+|set\s+\$${name})\s*=\s*([^;]+);`, 'gi'))];
    if (assigned.some(a => !/^true$/i.test(a[1].trim()))) return true;
  }
  return false;
}

// The text of each error handler body: `on error [without rollback] begin ... end error` (mdl 1)
// or `on error [without rollback] { ... }` (mdl 0), with the line it starts on.
function errorHandlers(flow) {
  const found = [];
  flow.lines.forEach((line, i) => {
    if (!/\bon\s+error\s+(?:without\s+rollback\s+)?(?:begin|\{)\s*$/i.test(line)) return;
    const braces = /\{\s*$/.test(line);
    const body = [];
    for (let j = i + 1; j < flow.lines.length; j++) {
      const next = flow.lines[j];
      if (braces ? /^\s*\}/.test(next) : /^\s*end\s+error\b/i.test(next)) break;
      body.push(next.trim());
    }
    found.push([flow.start + i, body.join(' ')]);
  });
  return found;
}

// [entity] a page saves with a Save changes button, per page: [page, entity, line].
function savedByPages(pageText) {
  const saved = [];
  let page = '', params = {}, start = 0, entities = [];
  const flush = text => {
    if (page && /save\s+changes/i.test(text)) for (const e of entities) saved.push([page, e, start]);
  };
  let text = '';
  pageText.split(/\r?\n/).forEach((line, i) => {
    const head = PAGE_HEAD.exec(line);
    if (head) { flush(text); page = head[1]; start = i + 1; params = {}; entities = []; text = ''; }
    if (!page) return;
    text += line + '\n';
    for (const m of line.matchAll(PARAM)) params[m[1]] = m[2];
    const dv = /\bdataview\s+\w+\s*\(\s*DataSource:\s*(?:\$(\w+)|database\s+(?:from\s+)?([\w.]+))/i.exec(line);
    if (dv) {
      const entity = dv[2] || params[dv[1]] || '';
      if (entity && !entities.includes(entity)) entities.push(entity);
    }
  });
  flush(text);
  return saved;
}

function eventFindings(flowLines, entityText, pageText) {
  const handlers = handlersOf(entityText);
  const flows = flowsOf(flowLines);
  const out = [];
  const committedOn = new Set();
  for (const [entity, list] of handlers) {
    for (const h of list) {
      if (h.event === 'commit') committedOn.add(entity);
      const flow = flows.get(h.flow);
      if (!flow) continue;
      // EVENT01: the commit handler commits its own object, with events.
      if (h.event === 'commit') {
        const own = Object.entries(paramsOf(flow)).filter(([, type]) => type === entity).map(([name]) => name);
        for (const p of own) {
          const re = new RegExp(String.raw`^\s*(?:commit\s+\$${p}\b|change\s+\$${p}\b.*\bcommit\b)(?![^;]*without\s+events)`, 'i');
          for (const [line, text] of where(flow, re)) {
            out.push(['EVENT01', `${h.flow}, the ${h.moment}-commit handler of ${entity}, commits $${p} -- the object it` +
              ` was called for -- with events: \`${text}\` runs the handler again, and again, a loop that crashes at` +
              ` runtime. ${h.moment === 'before' ? 'A before-commit handler only changes the attributes; the object is' +
              ' about to be saved anyway: drop the commit.' : `Commit it without events: \`commit $${p} without events;\`.`}`, line]);
          }
        }
      }
      // EVENT02: a before handler without raise error that can return false.
      if (h.moment === 'before' && !h.raises && canReturnFalse(flow)) {
        out.push(['EVENT02', `${h.flow}, the before-${h.event} handler of ${entity}, can return false and has no` +
          ` \`raise error\`: then the ${h.event} is skipped with no message and no trace -- a save the user believes` +
          ` happened. Add raise error to the handler (\`on before ${h.event} call ${h.flow}($currentObject) raise error\`),` +
          ' or check in the ACT_ microflow that saves, with validation feedback.', flow.start]);
      }
    }
  }
  for (const [name, flow] of flows) {
    // EVENT03: without events on an entity whose commit handler then does not run.
    const types = typesOf(flow);
    const re = /^\s*(?:commit\s+\$(\w+)|\$(\w+)\s*=\s*create\s+([\w.]+)|change\s+\$(\w+)).*\bwithout\s+events\b/i;
    flow.lines.forEach((line, i) => {
      const m = re.exec(line);
      if (!m) return;
      const variable = m[1] || m[2] || m[4];
      const entity = m[3] || types[variable] || '';
      if (!committedOn.has(entity)) return;
      const own = handlers.get(entity).filter(h => h.event === 'commit').map(h => h.flow);
      // Inside the entity's own commit handler, without events is the fix for EVENT01, not a skip.
      if (own.includes(name)) return;
      const names = own.join(', ');
      out.push(['EVENT03', `${name}: \`${line.trim()}\` commits a ${entity} without events, so its commit handler` +
        ` (${names}) does not run -- whatever it sets or checks is skipped for this object. If that is meant (a` +
        ' bulk import), set those values here; else drop `without events`.', flow.start + i]);
    });
    // ERR01: an error handler that nobody would notice.
    for (const [line, body] of errorHandlers(flow)) {
      if (/\blog\b|\braise\s+error\b|\bshow\s+message\b|\bvalidation\s+feedback\b|\breturn\b|\bcall\s+(?:microflow|nanoflow)\b|\bshow\s+page\b/i.test(body)) continue;
      out.push(['ERR01', `${name}: an error handler does nothing anyone sees (${body ? `\`${body.slice(0, 60)}\`` : 'it is empty'})` +
        ' -- the failure disappears without a trace. Log it (`log error \'...\' + $latestError/Message;`), tell' +
        ' the user, or `raise error;` to pass it on.', line]);
    }
  }
  // EVENT04: Save changes on an entity whose before-commit handler raises an error.
  const raising = new Map();
  for (const [entity, list] of handlers) {
    const h = list.find(x => x.moment === 'before' && x.event === 'commit' && x.raises);
    if (h) raising.set(entity, h.flow);
  }
  for (const [page, entity, line] of savedByPages(pageText || '')) {
    if (!raising.has(entity)) continue;
    out.push(['EVENT04', `${page} saves a ${entity} with Save changes, and ${raising.get(entity)} checks it in a` +
      ' before-commit handler that raises an error: a refused save shows "An error has occurred", not what to fix.' +
      ` Save through an ACT_ microflow that checks first and gives \`validation feedback $${entity.split('.').pop()}/<Attribute> message '<what to fix>';\`` +
      ', then commits; the handler can stay as the last guard.', line]);
  }
  return out;
}

module.exports = { eventFindings, handlersOf, canReturnFalse };
