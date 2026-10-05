// mxcli v0.25.0 describes in `mdl 1` (2026-10-05): rewrite that text into the v0.24 spelling the
// layout rules were written against, so both describe formats give the same findings.
//
// A text that does not carry an `mdl 1;` header line is returned as it is, so v0.24 input reaches
// the rules byte for byte unchanged. What mdl 1 changed for these rules:
//   - every description starts with `mdl 1;` (repeated in a concatenated dump), and ends `};`;
//   - DesignProperties are written in `( )` instead of `[ ]`, the Spacing group too;
//   - layout rows and columns, data grid columns, control bars, footers, chart series and gallery
//     templates have no name any more (v0.24 invented row1, col1, ...; describe no longer does);
//   - actions are spelled as statements: `call microflow`, `show page`, `close page`,
//     `save changes close page`, `create object`, `sign out`, `delete`;
//   - the navigation is `create or modify navigation`, its menu items are children in `{ }` with
//     their action and icon as properties: `menu item 'X' ( OnClick: show page M.P with (...), Icon: I )`;
//   - a user role is a property list, over several lines: `create or modify user role X (
//     ModuleRoles: (...), ManageAllRoles: true, CheckSecurity: true );`.
// A rewritten line keeps its place: a statement that spans lines is joined into its first line and
// the others are left empty, so a line number in a finding still points into the dump.
//
// Part of check_layout.cjs; see its header for inputs and the full rule table.
'use strict';

const MDL1_HEADER = /^[ \t]*mdl[ \t]+1[ \t]*;[ \t]*$/m;

const isMdl1 = text => typeof text === 'string' && MDL1_HEADER.test(text);

// The index of the `)` closing the `(` at open, skipping single-quoted strings ('' escapes a quote);
// -1 when the text ends first.
function closingParen(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === "'") {
      i++;
      while (i < text.length && !(text[i] === "'" && text[i + 1] !== "'")) i += text[i] === "'" ? 2 : 1;
      continue;
    }
    if (c === '(') depth++;
    else if (c === ')' && --depth === 0) return i;
  }
  return -1;
}

// DesignProperties: ( ... ( ... ) ) -> [ ... [ ... ] ]: the structural parentheses only, never
// those inside a value ('Horizontal (row)'). Characters are swapped one for one: lines stay put.
function designBrackets(text) {
  const out = text.split('');
  const find = /DesignProperties\s*:\s*\(/gi;
  let m;
  while ((m = find.exec(text))) {
    const open = m.index + m[0].length - 1;
    const close = closingParen(text, open);
    if (close < 0) continue;
    for (let i = open; i <= close; i++) {
      const c = text[i];
      if (c === "'") {
        i++;
        while (i <= close && !(text[i] === "'" && text[i + 1] !== "'")) i += text[i] === "'" ? 2 : 1;
        continue;
      }
      if (c === '(') out[i] = '[';
      else if (c === ')') out[i] = ']';
    }
  }
  return out.join('');
}

// Top-level `Key: value` pairs of a property list's inside, split on commas outside ( ) and quotes.
function properties(inside) {
  const props = new Map();
  let depth = 0, start = 0;
  const parts = [];
  for (let i = 0; i < inside.length; i++) {
    const c = inside[i];
    if (c === "'") {
      i++;
      while (i < inside.length && !(inside[i] === "'" && inside[i + 1] !== "'")) i += inside[i] === "'" ? 2 : 1;
      continue;
    }
    if (c === '(') depth++;
    else if (c === ')') depth--;
    else if (c === ',' && depth === 0) { parts.push(inside.slice(start, i)); start = i + 1; }
  }
  parts.push(inside.slice(start));
  for (const part of parts) {
    const m = /^\s*([A-Za-z_]\w*)\s*:\s*([\s\S]*?)\s*$/.exec(part);
    if (m) props.set(m[1].toLowerCase(), m[2]);
  }
  return props;
}

// An action as v0.24 wrote it, for `Action:` and the other action properties of a widget.
const ACTIONS = [
  [/^save\s+changes\s+close\s+page\b/i, 'save_changes close_page'],
  [/^cancel\s+changes\s+close\s+page\b/i, 'cancel_changes close_page'],
  [/^save\s+changes\b/i, 'save_changes'],
  [/^cancel\s+changes\b/i, 'cancel_changes'],
  [/^close\s+page\b/i, 'close_page'],
  [/^call\s+microflow\b/i, 'microflow'],
  [/^call\s+nanoflow\b/i, 'nanoflow'],
  [/^show\s+page\b/i, 'show_page'],
  [/^create\s+object\b/i, 'create_object'],
  [/^sign\s+out\b/i, 'sign_out'],
  [/^delete(?=\s*(?:[,)]|$))/i, 'delete_object'],
];
const ACTION_PROPERTY = /\b(?:Action|onClick|OnChange|OnEnter|OnLeave|OnClickAction)\s*:\s*/gi;

function actionsOf(line) {
  let out = '', at = 0, m;
  ACTION_PROPERTY.lastIndex = 0;
  while ((m = ACTION_PROPERTY.exec(line))) {
    const start = m.index + m[0].length;
    const rest = line.slice(start);
    for (const [from, to] of ACTIONS) {
      const action = from.exec(rest);
      if (action) {
        out += line.slice(at, start) + to;
        at = start + action[0].length;
        break;
      }
    }
  }
  return out + line.slice(at);
}

// The menu item of a navigation in v0.24's one-line form.
function menuItem(indent, caption, inside) {
  const props = inside === null ? new Map() : properties(inside);
  let target = '';
  const click = props.get('onclick');
  if (click) {
    const show = /^show\s+page\s+([\w.]+)/i.exec(click);
    const flow = /^call\s+(microflow|nanoflow)\s+([\w.]+)/i.exec(click);
    if (show) target = ` page ${show[1]}`;
    else if (flow) target = ` ${flow[1].toLowerCase()} ${flow[2]}`;
    else if (/^sign\s+out\b/i.test(click)) target = ' sign_out';
    else target = ' ' + click;
  }
  const icon = props.get('icon');
  return `${indent}menu item '${caption}'${target}${icon ? ' icon ' + icon : ''};`;
}

// v0.24's invented names for the widgets mdl 1 leaves unnamed, numbered per parent and type.
const ANONYMOUS = { row: 'row', footer: 'footer', controlbar: 'controlBar', series: 'series', template: 'template', header: 'header' };
const ANON_LINE = /^(\s*)(row|column|footer|controlbar|series|template|header)\s*(?=[({])/;
// Any widget opening line, named or not, for the nesting the counters are kept per parent.
const WIDGET_OPEN = /^(\s*)([a-z][a-z0-9_]*)(?:\s+(?:"[^"]+"|[A-Za-z_][\w/]*))?\s*[({]/;

// A data grid column's name as v0.24 printed it: its attribute, else its caption.
function columnName(statement, counter) {
  const attribute = /\bAttribute\s*:\s*([\w./]+)/i.exec(statement);
  if (attribute) {
    let name = attribute[1];
    // v0.24 printed an association by its own name, without the module.
    name = name.replace(/^[A-Za-z_]\w*\.(?=[A-Za-z_]\w*(?:\/|$))/, '');
    return /^[A-Za-z_]\w*$/.test(name) ? name : `"${name}"`;
  }
  const caption = /\bCaption\s*:\s*'((?:[^']|'')*)'/i.exec(statement);
  if (caption) return `"${caption[1].replace(/''/g, "'")}"`;
  return `col${counter}`;
}

function toMdl0(text) {
  if (!isMdl1(text)) return text;
  const lines = designBrackets(text).split('\n');
  const stack = [];          // open widgets: {indent, type, key}
  const counters = new Map();
  let nav = null;            // the navigation profile being read: its menu nesting
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    const trimmed = line.trim();
    if (/^mdl\s+1\s*;$/i.test(trimmed)) { lines[i] = ''; continue; }

    // Navigation.
    const profile = /^(\s*)create\s+or\s+modify\s+navigation\b(.*)$/i.exec(line);
    if (profile) { lines[i] = `${profile[1]}create or replace navigation${profile[2]}`; nav = []; continue; }
    if (nav !== null) {
      if (trimmed === '{' && !nav.length) { lines[i] = line.replace('{', 'menu ('); nav.push('menu'); continue; }
      if ((trimmed === '}' || trimmed === '};') && nav.length) {
        nav.pop();
        lines[i] = line.replace(/\};?/, ')');
        if (!nav.length) nav = null;
        continue;
      }
      const sub = /^(\s*)menu\s+'((?:[^']|'')*)'\s*(\((.*)\))?\s*\{\s*$/i.exec(line);
      if (sub) {
        const icon = sub[4] !== undefined ? properties(sub[4]).get('icon') : '';
        lines[i] = `${sub[1]}menu '${sub[2]}'${icon ? ' icon ' + icon : ''} (`;
        nav.push('sub');
        continue;
      }
    }
    const item = /^(\s*)menu\s+item\s+'((?:[^']|'')*)'\s*(\(.*)?$/i.exec(line);
    if (item) {
      let statement = item[3] || '';
      let j = i;
      while (statement && closingParen(statement, 0) < 0 && j + 1 < lines.length) {
        j++;
        statement += ' ' + lines[j].trim();
        lines[j] = '';
      }
      const close = statement ? closingParen(statement, 0) : -1;
      lines[i] = menuItem(item[1], item[2], close > 0 ? statement.slice(1, close) : null);
      continue;
    }

    // User roles: one line, `create user role X (module roles)[ manage all roles];`.
    const role = /^(\s*)create\s+or\s+modify\s+user\s+role\s+([\w.]+)\s*\(([\s\S]*)$/i.exec(line);
    if (role) {
      let statement = '(' + role[3];
      let j = i;
      while (closingParen(statement, 0) < 0 && j + 1 < lines.length) {
        j++;
        statement += ' ' + lines[j].trim();
        lines[j] = '';
      }
      const close = closingParen(statement, 0);
      const props = properties(statement.slice(1, close < 0 ? statement.length : close));
      const modules = (props.get('moduleroles') || '()').replace(/^\(\s*|\s*\)$/g, '');
      const manage = /^true$/i.test(props.get('manageallroles') || '') ? ' manage all roles' : '';
      lines[i] = `${role[1]}create user role ${role[2]} (${modules})${manage};`;
      continue;
    }

    // Pages, snippets and layouts.
    if (trimmed === '};') line = line.replace('};', '}');
    line = actionsOf(line);
    const anon = ANON_LINE.exec(line);
    const open = WIDGET_OPEN.exec(line);
    if (open && !['create', 'grant', 'layouttype', 'class', 'menu'].includes(open[2])) {
      const indent = open[1].length;
      while (stack.length && stack[stack.length - 1].indent >= indent) stack.pop();
      const parent = stack.length ? stack[stack.length - 1] : null;
      const type = open[2];
      if (anon) {
        const key = `${parent ? parent.line : -1}:${type}`;
        const n = (counters.get(key) || 0) + 1;
        counters.set(key, n);
        let name;
        if (type !== 'column') name = `${ANONYMOUS[type]}${n}`;
        else if (parent && parent.type === 'row') name = `col${n}`;
        else {
          let statement = line;
          if (/\($/.test(line.trimEnd())) {
            for (let j = i + 1; j < lines.length && !/^\s*\)/.test(lines[j]); j++) statement += ' ' + lines[j];
          }
          name = columnName(statement, n);
        }
        line = `${anon[1]}${type} ${name} ${line.slice(anon[0].length).trimStart()}`;
      }
      stack.push({ indent, type, line: i });
    }
    lines[i] = line;
  }
  return lines.join('\n');
}

module.exports = { isMdl1, toMdl0, designBrackets, properties, closingParen };
