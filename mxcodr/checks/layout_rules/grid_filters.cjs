// GRID03: every data grid column that shows an attribute has a filter.
//
// Part of check_layout.cjs; see its header for inputs and the full rule table. Written for Node,
// so it uses plain RegExp, like inputs.cjs.
//
// A data grid is where users look for rows, and the rows grow with the app's life: a grid of five
// parts today holds five hundred next year. So every column bound to an attribute carries the
// filter that matches the attribute's type, on every grid -- overview and detail grids alike, with
// no regard to how many rows it shows now. Columns without an Attribute (buttons, custom content)
// have nothing to filter on and are left alone. Boolean is filtered too: Data Grid 2's drop-down
// filter takes Enumeration and Boolean attributes (DatagridDropdownFilter 3.4.0, checked with
// mx check on Mendix 11.12.1).
'use strict';
const py = require('../py_compat.cjs');
const { depthChange } = require('./mdl_text.cjs');

const DOCUMENT = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(page|snippet)\s+([\w.]+)/i;
const GRID = /^\s*datagrid\s+("[^"]*"|\w+)/i;
// `column (Attribute: X ...)` (mdl 1) or `column X (Attribute: X ...)` (the v0.24 spelling the rules read).
const COLUMN = /^\s*column\b(?:\s+(?:"[^"]*"|[\w/.]+))?\s*\(/i;
const FILTER = /^\s*(textfilter|numberfilter|datefilter|dropdownfilter)\b/i;
const CONTEXT = /^\s*--\s*Context:\s*\$currentObject\s*\(([^),\s]+)/;
const SOURCE_DATABASE = /\bDataSource:\s*database\s+(?:from\s+)?(\w+\.\w+)/i;
const ATTRIBUTE = /\bAttribute:\s*"?([\w/.]+?)"?\s*[,)]/i;
const CAPTION = /\bCaption:\s*'((?:[^']|'')*)'/i;

const ENTITY_HEAD = /^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:persistent\s+|non-persistent\s+|view\s+)?entity\s+(\w+\.(?:"[^"]+"|\w+))/i;
// `Name: String(200)`, `"Status": Enumeration(Mod.Status) default ...`, `Active: Boolean default false`.
const ATTRIBUTE_DECL = /^\s*"?(\w+)"?\s*:\s*(\w+)/;

const TYPE_FILTERS = [
  [/^(string|hashedstring)$/i, 'textfilter', ''],
  [/^(integer|long|decimal|autonumber)$/i, 'numberfilter', ''],
  [/^(datetime|date)$/i, 'datefilter', ' (FilterType: between)'],
  [/^(enumeration|enum|boolean)$/i, 'dropdownfilter', ''],
];
const TABLE = 'String: textfilter; Integer, Long, Decimal, AutoNumber: numberfilter; Date and time:' +
  ' datefilter (FilterType: between); Enumeration and Boolean: dropdownfilter; a path over an' +
  ' association: dropdownfilter (Association: Mod.Assoc, datasource: database Mod.Other, CaptionAttribute: Attr)';

const unquote = name => name.split('"').join('');

// {Module.Entity: {Attribute: Type}} from `describe entity` dumps.
function attributeTypes(entityText) {
  const entities = Object.create(null);
  let current = null;
  for (const line of py.splitlines(entityText || '')) {
    const head = ENTITY_HEAD.exec(line);
    if (head) {
      current = Object.create(null);
      entities[unquote(head[1])] = current;
      continue;
    }
    if (!current) continue;
    if (/^\s*\)/.test(line)) { current = null; continue; }
    const attr = ATTRIBUTE_DECL.exec(line);
    if (attr) current[attr[1]] = attr[2];
  }
  return entities;
}

// A widget's header: its line and the lines below until it opens a body (`{`) or closes (`)`).
// Brackets are counted outside quotes: a multi-line column whose ContentParams line ends in
// `formatDateTime(...))` closed the header there, so its body's datefilter went unseen and GRID03
// blocked a column that had one (room-booking m1, 2026-10-14, after the DATE01 fix).
function headerOf(lines, index) {
  let end = index, parens = 0;
  while (end < lines.length - 1) {
    const bare = lines[end].replace(/'(?:[^']|'')*'/g, "''");
    parens += (bare.split('(').length - 1) - (bare.split(')').length - 1);
    const r = py.rstrip(lines[end]);
    if (parens <= 0 && (r.endsWith('{') || r.endsWith(')') || r.endsWith(');'))) break;
    end++;
  }
  return { text: lines.slice(index, end + 1).join(' '), end, opens: py.rstrip(lines[end]).endsWith('{') };
}

// The entity a grid shows: mxcli's `-- Context:` line under it, else `DataSource: database`.
function gridEntity(lines, header) {
  for (let look = header.end + 1; look < Math.min(lines.length, header.end + 4); look++) {
    const context = CONTEXT.exec(lines[look]);
    if (context) return context[1];
  }
  const db = SOURCE_DATABASE.exec(header.text);
  return db ? db[1] : '';
}

// The entity on the other side of `Assoc/Attr`: the one named like the association's end
// (`Invoice_Customer` -> `Customer`) with that attribute, else the only other entity that has it.
function targetEntity(entities, gridEntityName, association, attribute) {
  const end = association.split('_').pop().toLowerCase();
  const owners = Object.keys(entities).filter(name => name !== gridEntityName && attribute in entities[name]);
  const named = owners.find(name => name.split('.').pop().toLowerCase() === end);
  if (named) return named;
  return owners.length === 1 ? owners[0] : '';
}

// `JobOverview_JobsGrid` -> `JobOverview`; the caption or attribute as a name part -> `What`.
const prefixOf = grid => (grid.includes('_') ? grid.split('_')[0] : grid);
function namePart(caption, attribute) {
  const words = (caption || attribute.split('/').pop()).match(/[A-Za-z0-9]+/g) || ['Column'];
  return words.map(w => w[0].toUpperCase() + w.slice(1)).join('');
}

// The filter a column wants, as MDL, or '' when the attribute's type is not known.
function suggestion(entities, grid, attribute, caption) {
  const name = `${prefixOf(grid.name)}_${namePart(caption, attribute)}Filter`;
  const module = grid.entity ? grid.entity.split('.')[0] : '';
  if (attribute.includes('/')) {
    const parts = attribute.split('/');
    const association = parts[0].includes('.') ? parts[0] : (module ? `${module}.${parts[0]}` : parts[0]);
    const shown = parts[parts.length - 1];
    const target = parts.length === 2 ? targetEntity(entities, grid.entity, parts[0], shown) : '';
    return `dropdownfilter ${name} (Association: ${association}, datasource: database` +
      ` ${target || `<the entity ${association} points to -- describe association ${association}>`}, CaptionAttribute: ${shown})`;
  }
  const type = grid.entity && entities[grid.entity] ? entities[grid.entity][attribute] : undefined;
  if (!type) return '';
  for (const [pattern, widget, props] of TYPE_FILTERS) if (pattern.test(type)) return `${widget} ${name}${props}`;
  return '';
}

// GRID03 findings for every data grid column on the pages and snippets in <lines>.
function missingFilterFindings(lines, entityText) {
  const entities = attributeTypes(entityText);
  const failures = [];
  let documentName = '';
  let depth = 0;
  const grids = [];   // {name, entity, at: depth of its body, opened}
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    const head = DOCUMENT.exec(line);
    if (head) {
      documentName = head[2];
      depth = 0;
      grids.length = 0;
    }
    const top = grids[grids.length - 1];
    const grid = GRID.exec(line);
    if (grid) {
      const header = headerOf(lines, index);
      grids.push({ name: unquote(grid[1]), entity: gridEntity(lines, header), at: depth + 1, opened: false });
    } else if (top && top.opened && depth === top.at && COLUMN.test(line)) {
      const header = headerOf(lines, index);
      const attr = ATTRIBUTE.exec(header.text);
      if (attr) {
        let filtered = false;
        if (header.opens) {
          // The column's own body, one level down: a filter there filters this column.
          let inner = 0;
          for (let look = index; look < lines.length; look++) {
            if (look > header.end && inner === 1 && FILTER.test(lines[look])) { filtered = true; break; }
            inner += depthChange(lines[look]);
            if (look >= header.end && inner <= 0) break;
          }
        }
        if (!filtered) {
          const caption = CAPTION.exec(header.text);
          const captionText = caption ? caption[1].replace(/''/g, "'") : '';
          const filter = suggestion(entities, top, attr[1], captionText);
          const type = !attr[1].includes('/') && top.entity && entities[top.entity] ? entities[top.entity][attr[1]] : '';
          const what = `${captionText ? `'${captionText}' ` : ''}(Attribute: ${attr[1]}${type ? ', ' + type : ''})`;
          const column = `column (Attribute: ${attr[1]}${captionText ? `, Caption: '${caption[1]}'` : ''})`;
          failures.push({
            check: 'GRID03',
            line: index + 1,
            document: documentName,
            message: `${documentName}: column ${what} in data grid ${top.name} has no filter -- users cannot` +
              ' narrow the rows by it, and the rows grow with the app. ' +
              (filter
                ? `Add it inside the column: \`${column} { ${filter} }\``
                : `Add the filter that matches its type inside the column (${TABLE}), e.g. \`${column} { textfilter ${prefixOf(top.name)}_${namePart(captionText, attr[1])}Filter }\` for a String`),
          });
        }
      }
    }
    depth += depthChange(line);
    const last = grids[grids.length - 1];
    if (last && !last.opened) {
      if (depth >= last.at) last.opened = true;
      else if (/^\s*\)\s*;?\s*$/.test(line) && index > 0) {
        // `)` that closes a grid's properties with no `{` after it: the grid has no body.
        const r = py.rstrip(line);
        if (r.endsWith(')') || r.endsWith(');')) grids.pop();
      }
    }
    while (grids.length && grids[grids.length - 1].opened && depth < grids[grids.length - 1].at) grids.pop();
  }
  return failures;
}

module.exports = { missingFilterFindings, attributeTypes };
