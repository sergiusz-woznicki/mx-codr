// LIST01: a list view item lays out as a card: what the item is on the left, what you do with it
// on the right. Measured on OfflineLab 2026-10-11 (390 px): every value and the Open button stacked
// down the left edge, a 205 px card with the right half empty; the item's texts in one box and its
// buttons in another, side by side in a row that does not wrap, gave a 160 px card, the button on
// the right, and passed mx check. On a desktop-wide list the same row keeps the button at the edge.
//
// Part of check_layout.cjs; see its header for inputs and the full rule table.
'use strict';
const { WIDGET_LINE_RE, BACK_WRAPPERS, indentOf } = require('./pages.cjs');

const ROW = /'Flex container'\s*:\s*'Horizontal \(row\)'/;
const SPREAD = /'Align items X'\s*:\s*'(Space between|Right)/;
const NOWRAP = /'Disable row wrap'\s*:\s*ON\b/i;
const DOC = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(page|snippet)\s+([\w.]+)/i;
const BUTTON = new Set(['actionbutton', 'linkbutton']);

// The header of the widget on line <at>, over the lines it runs on.
function headAt(lines, at) {
  let text = lines[at];
  for (let i = at + 1; i < lines.length && !/[{]\s*$/.test(text) && !/\)\s*;?\s*$/.test(text); i++) text += ' ' + lines[i].trim();
  return text;
}

// The line that closes the block opened at or after line <at>.
function blockEnd(lines, at) {
  const own = indentOf(lines[at]);
  const open = lines.findIndex((line, i) => i >= at && /\{\s*$/.test(line));
  if (open < 0) return at;
  const end = lines.findIndex((line, i) => i > open && line.trim().startsWith('}') && indentOf(line) <= own);
  return end < 0 ? lines.length : end;
}

function listItemFindings(lines) {
  const out = [];
  let doc = '';
  for (let at = 0; at < lines.length; at++) {
    const d = DOC.exec(lines[at]);
    if (d) { doc = d[2]; continue; }
    const lv = /^\s*listview\s+(\w+)/i.exec(lines[at]);
    if (!lv || !doc) continue;
    const end = blockEnd(lines, at);
    const widgets = [], rows = [], loose = [];
    for (let i = at + 1; i < end; i++) {
      const line = lines[i];
      if (line.trim().startsWith('--')) continue;
      const m = WIDGET_LINE_RE.match(line);
      if (!m) continue;
      const type = m.group('type').toLowerCase();
      if (type === 'listview') { i = blockEnd(lines, i); continue; }  // a list inside the item is judged on its own
      if (type === 'container') {
        const head = headAt(lines, i);
        if (ROW.test(head)) (SPREAD.test(head) && NOWRAP.test(head) ? rows : loose).push([i, blockEnd(lines, i)]);
        continue;
      }
      if (BACK_WRAPPERS.has(type)) continue;
      widgets.push({ type, name: m.group('name'), at: i });
    }
    const buttons = widgets.filter(w => BUTTON.has(w.type));
    const content = widgets.filter(w => !BUTTON.has(w.type));
    if (!buttons.length || !content.length) continue;
    const inside = (w, [a, b]) => w.at > a && w.at < b;
    const beside = buttons.every(b => rows.some(r => inside(b, r) && content.some(c => inside(c, r))));
    if (beside) continue;
    // Names from the list's own (MyJobs_JobsList -> MyJobs_JobsCardBox), so two lists on a page do not share them.
    const prefix = lv[1].replace(/(List|Gallery)$/, '') || lv[1];
    const top = lines.slice(at + 1, end).map(line => /^\s*container\s+(\w+)/i.exec(line)).find(Boolean);
    const kept = /'padding'\s*:\s*'(S|M|L)'/i.exec(lines.slice(at, end).join(' '));
    // In a row already, but straight after the text and free to wrap: the button is not at the edge either.
    const inRow = buttons.some(b => loose.some(r => inside(b, r) && content.some(c => inside(c, r))));
    const now = inRow
      ? `puts ${buttons.map(b => b.name).join(', ')} straight after its item's ${content.length} text(s), in a row that may wrap,` +
        ' so the button lands mid-line or under the text and the right of the item stays empty'
      : `stacks ${buttons.map(b => b.name).join(', ')} under its item's ${content.length} text(s), down the left edge, and leaves` +
        ' the right of every item empty';
    out.push({ check: 'LIST01', line: 0, message: `${doc}: list view ${lv[1]} ${now}. An item reads as` +
      ` what it is on the left and what you do with it on the right: ${top ? `replace ${top[1]} with` : 'make its content'}` +
      ` container ${prefix}CardBox (DesignProperties: ('Flex container': 'Horizontal (row)', 'Align items X': 'Space between` +
      ` (only for horizontal containers)', 'Align items Y': 'Center', 'Disable row wrap': ON, 'Spacing': ('padding': '${kept ? kept[1] : 'M'}')))` +
      ` { container ${prefix}InfoBox { <${content.map(c => c.name).join(', ')}, as they are> }` +
      ` container ${prefix}ActionsBox { <${buttons.map(b => b.name).join(', ')}, as they are> } } -- 'Disable row wrap' keeps` +
      ' the buttons beside the text on a phone (a long text wraps inside its own box). The widgets keep their names, so a test' +
      ' still finds them' });
  }
  return out;
}

module.exports = { listItemFindings };
