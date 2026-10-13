// TABS02: two or more lists on one page, one under another, go in tabs.
// KPI01: a list over a view that always holds one row (totals with no group by) is figures: tiles.
//
// Part of check_layout.cjs; see its header for inputs and the full rule table.
//
// A page that stacks data grids, list views or galleries makes the person scroll past the first
// list to find the second, and the page reads as one long report (a stock dashboard stacked its
// stock value per category over the products to reorder, 2026-10-13). One tab a list, the
// heading over each list as its tab's caption. Lists side by side -- in columns of one row, each
// narrower than the page -- are not stacked; a list inside a tab page already has its tab.
'use strict';
const { documentKey } = require('./names.cjs');

const DOCUMENT = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(page)\s+([\w.]+)/i;
const LIST = /^\s*(datagrid|listview|gallery)\s+([A-Za-z_]\w*)/i;
const ROW = /^\s*row\b/i;
const COLUMN = /^\s*column\s*\(([^)]*)\)/i;
const TABPAGE = /^\s*tabpage\b/i;
const indentOf = line => line.length - line.trimStart().length;
const SOURCE = /\bDataSource\s*:\s*database\s+(?:from\s+)?([\w.]+)/i;

// {Entity: [attribute names]} of the view entities whose query always returns one row: an aggregate
// (count, sum, avg, min, max) and no `group by`. A grid over one is a row of figures in a table
// frame (a stock dashboard's "Total stock value | Products | Need reorder", 2026-10-13).
function oneRowViews(entityText) {
  const out = {};
  const re = /create\s+(?:or\s+(?:modify|replace)\s+)?view\s+entity\s+([\w.]+)\s*\(([\s\S]*?)\)\s*as\s*\(([\s\S]*?)\)\s*;/gi;
  for (const m of String(entityText || '').matchAll(re)) {
    const query = m[3];
    if (!/\b(count|sum|avg|min|max)\s*\(/i.test(query) || /\bgroup\s+by\b/i.test(query)) continue;
    out[m[1]] = [...m[2].matchAll(/^\s*"?(\w+)"?\s*:/gm)].map(a => a[1]);
  }
  return out;
}

// [findings]: {check, line, message, document}, one per page.
function listTabsFindings(lines, entityText) {
  const findings = [];
  const views = oneRowViews(entityText);
  let doc = null;
  const flush = () => {
    if (!doc) return;
    // A band is what stacks: lists in columns of one row, each narrower than the page, are one band.
    const bands = [];
    const key = documentKey('page', doc.name);
    for (const list of doc.lists.filter(l => views[l.source])) {
      const attrs = views[list.source];
      const tiles = attrs.map(a => `column (DesktopWidth: ${Math.max(3, Math.floor(12 / Math.min(attrs.length, 4)))}) { container ${key}_${a}Box (Class: 'card') { ` +
        `dynamictext ${key}_${a}LabelText (Content: '<what it is>', RenderMode: H6) dynamictext ${key}_${a}Text (Content: '{1}', ContentParams: ({1} = ${a}), RenderMode: H3) } }`);
      findings.push({
        check: 'KPI01', line: list.line, document: doc.name,
        message: `${doc.name}: ${list.type} ${list.name} shows ${list.source}, which always holds one row (totals, no group by): ` +
          `figures in a table frame. Show them as tiles, one card a figure: a microflow DS_${list.source.split('.').pop()} () returns ${list.source} ` +
          `that retrieves it with \`first\`, then dataview ${key}_${list.source.split('.').pop()}Form (DataSource: microflow <that DS_>) ` +
          `{ layoutgrid ${key}_${list.source.split('.').pop()}Layout { row { ${tiles.join(' ')} } } } in place of the ${list.type}.`,
      });
    }
    for (const list of doc.lists.filter(l => !views[l.source])) {
      const side = list.row !== null && list.width && list.width < 12;
      const band = side && bands.find(b => b.row === list.row && b.side);
      if (band) band.lists.push(list); else bands.push({ row: list.row, side, lists: [list] });
    }
    if (bands.length >= 2) {
      const stacked = bands.flatMap(b => b.lists);
      const tabs = stacked.map(l => {
        const what = l.name.replace(new RegExp(`^${key}_`), '').replace(/(Grid|List|Gallery)$/, '') || 'Items';
        return `tabpage ${key}_${what}Tab (Caption: '${l.heading || what.replace(/([a-z])([A-Z])/g, '$1 $2')}') { <${l.name}, as it is> }`;
      });
      findings.push({
        check: 'TABS02', line: stacked[0].line, document: doc.name,
        message: `${doc.name}: ${stacked.length} lists one under another (${stacked.map(l => l.name).join(', ')}): the person ` +
          `scrolls past one to find the next. Put them in tabs, one list a tab, the heading over each as its caption: ` +
          `tabcontainer ${key}_ListsTabs { ${tabs.join(' ')} } -- in one row and column, in place of the rows they were in.`,
      });
    }
    doc = null;
  };
  // The open blocks above the current line: [{indent, kind, row, width}].
  let stack = [];
  let lastHeading = '';
  lines.forEach((line, i) => {
    const head = DOCUMENT.exec(line);
    if (head) { flush(); doc = { name: head[2], lists: [] }; stack = []; lastHeading = ''; return; }
    if (/^\s*create\b/i.test(line)) { flush(); return; }
    if (!doc || !line.trim()) return;
    const indent = indentOf(line);
    while (stack.length && stack[stack.length - 1].indent >= indent) stack.pop();
    const text = /\bContent:\s*'((?:[^']|'')*)'/.exec(line);
    if (/^\s*dynamictext\b/i.test(line) && text && !/\{\d+\}/.test(text[1])) lastHeading = text[1].replace(/''/g, "'");
    const list = LIST.exec(line);
    if (list) {
      if (!stack.some(b => b.kind === 'tabpage')) {
        const row = [...stack].reverse().find(b => b.kind === 'row');
        const column = [...stack].reverse().find(b => b.kind === 'column');
        const src = SOURCE.exec(line);
        doc.lists.push({ type: list[1].toLowerCase(), name: list[2], line: i + 1, row: row ? row.line : null, width: column ? column.width : 0, heading: lastHeading, source: src ? src[1] : '' });
      }
      lastHeading = '';
    }
    let kind = '';
    let width = 0;
    if (ROW.test(line)) kind = 'row';
    else if (COLUMN.test(line)) {
      kind = 'column';
      const w = /\bDesktopWidth:\s*(\d+)/i.exec(COLUMN.exec(line)[1]);
      width = w ? Number(w[1]) : 0;
    } else if (TABPAGE.test(line)) kind = 'tabpage';
    if (kind || /[{(]\s*$/.test(line)) stack.push({ indent, kind: kind || 'block', line: i + 1, width });
  });
  flush();
  return findings;
}

module.exports = { listTabsFindings, oneRowViews };
