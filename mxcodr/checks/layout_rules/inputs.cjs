// TEXT01 (a long text attribute edited in a one-line textbox) and TEXT02 (a textbox whose
// attribute's name says it holds prose).
//
// Part of check_layout.cjs; see its header for inputs and the full rule table. Unlike the rules
// ported from check_layout.py, these were written for Node, so they use plain RegExp.
//
// A textbox is one line: a description, a note or a reason typed into it scrolls sideways, and
// the line breaks a user types are lost on screen. The entity says how long the text may be;
// past LONG characters (or unlimited) the field wants a textarea, and that blocks DONE. A name
// alone (Description, Notes, Reason ...) is only a hint -- `Summary String(100)` may well be one
// line on purpose -- so it is a warning, and a short attribute (under SHORT) is left alone.
'use strict';
const py = require('../py_compat.cjs');

const LONG = 500;
const SHORT = 100;
const PROSE = /(description|notes?|comments?|remarks?|details|body|message|summary|reason|instructions|explanation|feedback|biography|bio)$/i;

const ENTITY_HEAD = /^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:persistent\s+|non-persistent\s+|view\s+)?entity\s+(\w+\.(?:"[^"]+"|\w+))/i;
// `Notes: String(2000)`, `"Notes": String(unlimited)`; mxcli reads a bare `String` as unlimited.
const STRING_ATTR = /^\s*"?(\w+)"?\s*:\s*String\b(?:\(\s*(\w+)\s*\))?/i;
const DOCUMENT = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(?:page|snippet)\s+([\w.]+)/i;
const PARAM = /\$(\w+)\s*:\s*(\w+\.\w+)/g;
const WIDGET = /^\s*([a-z]+)\s+("[^"]*"|[\w.]+)\s*[({]/i;
const DATA_WIDGETS = new Set(['dataview', 'listview', 'gallery', 'datagrid', 'templategrid']);
const CONTEXT = /^\s*--\s*Context:\s*\$currentObject\s*\(([^)]+)\)/;
const SOURCE_PARAM = /\bDataSource:\s*\$(\w+)(?![\w/])/i;
const SOURCE_DATABASE = /\bDataSource:\s*database\s+(?:from\s+)?(\w+\.\w+)/i;
const SOURCE_SELECTION = /\bDataSource:\s*selection\s+(\w+)/i;
// `Attribute: Notes`; a path (`Invoice_Customer/Name`) belongs to another entity and is skipped.
const ATTRIBUTE = /\bAttribute:\s*"?(\w+)"?(?![\w/.])/;
const LABEL = /\bLabel:\s*'([^']*)'/;

const unquote = name => name.split('"').join('');
const isLong = length => length === Infinity || length > LONG;
const shown = length => (length === Infinity ? 'unlimited' : String(length));

// {Module.Entity: {Attribute: length}} for every String attribute; unlimited is Infinity.
function stringLengths(entityText) {
  const entities = Object.create(null);
  let current = null;
  for (const line of py.splitlines(entityText)) {
    const head = ENTITY_HEAD.exec(line);
    if (head) {
      current = Object.create(null);
      entities[unquote(head[1])] = current;
      continue;
    }
    if (!current) continue;
    const attr = STRING_ATTR.exec(line);
    if (attr) {
      const size = attr[2];
      current[attr[1]] = !size || /^unlimited$/i.test(size) ? Infinity : Number(size);
    }
    if (/^\s*\)/.test(line)) current = null;
  }
  return entities;
}

// A widget's properties: its line, and the lines below while it is still open with `(`.
function propsOf(lines, index) {
  let props = lines[index];
  if (/\(\s*$/.test(props)) {
    for (let look = index + 1; look < lines.length && !/^\s*\)/.test(lines[look]); look++) props += ' ' + py.strip(lines[look]);
  }
  return props;
}

// Braces that open or close a block: not inside a quoted caption, not `{1}` of ContentParams.
function depthChange(line) {
  const bare = line.replace(/'(?:[^']|'')*'/g, "''").replace(/\{\d+\}/g, '');
  return (bare.split('{').length - 1) - (bare.split('}').length - 1);
}

// The entity a data widget gives the widgets inside it, or '' when it cannot be told.
function sourceEntity(lines, index, props, params, named, entities) {
  // mxcli prints the context under the widget; it names the entity for a microflow source.
  for (let look = index + 1; look < Math.min(lines.length, index + 4); look++) {
    const context = CONTEXT.exec(lines[look]);
    if (context) {
      const name = py.strip(context[1].split(',')[0]);
      if (entities[name]) return name;
      break;
    }
  }
  let found = SOURCE_PARAM.exec(props);
  if (found) return params[found[1]] || '';
  found = SOURCE_DATABASE.exec(props);
  if (found) return found[1];
  found = SOURCE_SELECTION.exec(props);
  if (found) return named[found[1]] || '';
  return '';
}

// The length of <attribute> in <entity>; with no entity, the shortest length any of the
// project's entities gives that attribute name, so an unknown source never blocks a short field.
function lengthOf(entities, entity, attribute) {
  if (entity) return entities[entity] && attribute in entities[entity] ? [entities[entity][attribute], entity] : [null, entity];
  const owners = Object.keys(entities).filter(name => attribute in entities[name]);
  if (!owners.length) return [null, ''];
  const shortest = Math.min(...owners.map(name => entities[name][attribute]));
  return [shortest, owners.length === 1 ? owners[0] : ''];
}

// [failures, warnings] for every textbox on the pages and snippets in <lines>.
function textInputFindings(lines, entityText) {
  const entities = stringLengths(entityText);
  const failures = [], warnings = [];
  let documentName = '', params = Object.create(null), named = Object.create(null);
  let depth = 0;
  // Data widgets around the current line: {at: depth of its body, entity, opened: body seen}.
  // Properties may run over several lines, so the body's `{` can come a few lines later.
  const open = [];
  lines.forEach((line, index) => {
    const head = DOCUMENT.exec(line);
    if (head) {
      documentName = head[1];
      params = Object.create(null);
      named = Object.create(null);
      open.length = 0;
      depth = 0;
    }
    if (/\bParams\s*:/.test(line)) {
      for (const p of line.matchAll(PARAM)) params[p[1]] = p[2];
    }
    const widget = WIDGET.exec(line);
    const type = widget ? widget[1].toLowerCase() : '';
    if (widget && DATA_WIDGETS.has(type)) {
      const props = propsOf(lines, index);
      const entity = sourceEntity(lines, index, props, params, named, entities);
      named[unquote(widget[2])] = entity;
      // A one-line widget with no body opens nothing.
      if (line.includes('{') || /\(\s*$/.test(line)) open.push({ at: depth + 1, entity, opened: false });
    } else if (type === 'textbox') {
      const props = propsOf(lines, index);
      const attr = ATTRIBUTE.exec(props);
      if (attr) {
        const inner = open.filter(o => o.opened);
        const entity = inner.length ? inner[inner.length - 1].entity : '';
        const [length, owner] = lengthOf(entities, entity, attr[1]);
        const name = unquote(widget[2]);
        const label = LABEL.exec(props);
        const field = `${owner ? owner + '.' : ''}${attr[1]}`;
        const fix = `\`alter page ${documentName} { replace ${name} with { textarea ${name}` +
          ` (Label: '${label ? label[1] : attr[1]}', Attribute: ${attr[1]}) } };\``;
        if (length !== null && isLong(length)) {
          failures.push({
            check: 'TEXT01',
            line: index + 1,
            message: `${documentName}: textbox ${name} edits ${field}, a String(${shown(length)}) -- a one-line` +
              ' box shows a sliver of a long text and loses its line breaks on screen. Make it a textarea, e.g. ' + fix,
          });
        } else if (PROSE.test(attr[1]) && (length === null || length >= SHORT)) {
          warnings.push({
            check: 'TEXT02',
            line: index + 1,
            message: `${documentName}: textbox ${name} edits ${field}` +
              `${length !== null ? ', a String(' + shown(length) + ')' : ''}, and its name says it holds prose --` +
              ` if people write more than a line there, make it a textarea, e.g. ${fix}`,
          });
        }
      }
    }
    depth += depthChange(line);
    const last = open[open.length - 1];
    if (last && !last.opened) {
      if (depth >= last.at) last.opened = true;
      // `)` that closes the properties with no `{` after it: the widget has no body.
      else if (/^\s*\)\s*;?\s*$/.test(line)) open.pop();
    }
    while (open.length && open[open.length - 1].opened && depth < open[open.length - 1].at) open.pop();
  });
  return [failures, warnings];
}

module.exports = { textInputFindings, stringLengths, LONG, SHORT };
