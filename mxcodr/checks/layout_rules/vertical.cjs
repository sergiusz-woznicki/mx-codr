// SPACE04 (a button or a line of text touching the box above or below it: a data grid, a list,
// a card).
//
// Part of check_layout.cjs; see its header for inputs and the full rule table. Written for Node
// after the port from check_layout.py, so `--port-parity` leaves it out.
//
// Atlas gives buttons and text no vertical margin, and a data grid, list view or card none
// either: put one under the other and they touch. A session put "Generate invoice" in the
// grid's controlbar, as GRID02 asks, and the button sat on the grid's header row. SPACE01-03
// look at widgets that share a line; this looks at the widget above and below.
'use strict';
const { isHeading, parse, spacingOf, INLINE, STRUCTURAL } = require('./pages.cjs');

// Widgets that draw a box (rows, a border, a background): text against them reads as glued on.
const BOXES = new Set(['datagrid', 'listview', 'gallery', 'templategrid', 'groupbox', 'tabcontainer']);
// A container or data view is a box only when a class or a design property paints one.
const BOX_CLASS = /Class:\s*'[^']*\b(?:card|well|alert(?:-[\w-]+)?)\b/;
const BOX_DESIGN = /'Background color'\s*:/;
const LISTS = new Set(['datagrid', 'gallery', 'listview', 'templategrid']);
const BUTTONS = new Set(['actionbutton', 'linkbutton']);

const margin = (widget, side) => {
  const value = spacingOf(widget).get(`margin-${side}`);
  return value && value !== 'None' ? value : '';
};
const isBox = widget => BOXES.has(widget.type) ||
  ((widget.type === 'container' || widget.type === 'dataview') && (BOX_CLASS.test(widget.text) || BOX_DESIGN.test(widget.text)));
const isLine = widget => INLINE.has(widget.type) && !STRUCTURAL.has(widget.type) && !isHeading(widget);
const label = widget => `${widget.type}${widget.name ? " '" + widget.name + "'" : ''}`;
const add = side => ` -- add DesignProperties: ['Spacing': ['margin-${side}': 'S']]`;

// [[widget, its parent or null, its siblings in order]] for every widget.
function tree(widgets) {
  const parentOf = new Map(), children = new Map();
  widgets.forEach((widget, index) => {
    let parent = null;
    for (let j = index - 1; j >= 0; j--) {
      if (widgets[j].page !== widget.page) break;
      if (widgets[j].indent < widget.indent) { parent = widgets[j]; break; }
    }
    parentOf.set(widget, parent);
    if (!children.has(parent)) children.set(parent, []);
    children.get(parent).push(widget);
  });
  return [parentOf, children];
}

// SPACE03 already reports a line of two or more where nothing has margin-bottom.
function unspacedLine(group, widget) {
  const index = group.indexOf(widget);
  let start = index, end = index;
  while (start > 0 && isLine(group[start - 1])) start--;
  while (end < group.length - 1 && isLine(group[end + 1])) end++;
  const run = group.slice(start, end + 1);
  return run.length > 1 && run.every(w => !margin(w, 'bottom'));
}

function verticalFindings(lines) {
  const widgets = parse(lines);
  const [parentOf, children] = tree(widgets);
  const failures = [];
  // A list whose item ends in a margin (badges with margin-bottom) already leaves the gap.
  const endsSpaced = box => {
    const inside = children.get(box) || [];
    return inside.length > 0 && Boolean(margin(inside[inside.length - 1], 'bottom'));
  };
  for (const [parent, group] of children) {
    // A grid's own header: the buttons sit on its first row unless they keep a margin.
    const grid = parent && parent.type === 'controlbar' ? parentOf.get(parent) : null;
    if (grid && LISTS.has(grid.type)) {
      for (const widget of group) {
        if (!BUTTONS.has(widget.type) || margin(widget, 'bottom') || unspacedLine(group, widget)) continue;
        failures.push({
          check: 'SPACE04',
          line: widget.line,
          message: `${widget.page}: ${label(widget)} in the header of ${label(grid)} sits right on its` +
            ' first row, with no space between them' + add('bottom'),
        });
      }
    }
    group.slice(0, -1).forEach((above, index) => {
      const below = group[index + 1];
      if (margin(above, 'bottom') || margin(below, 'top')) return;
      if (isLine(above) && isBox(below) && !unspacedLine(group, above)) {
        failures.push({
          check: 'SPACE04',
          line: above.line,
          message: `${above.page}: ${label(above)} sits right on top of ${label(below)}, with no space` +
            ' between them' + add('bottom'),
        });
      } else if (isBox(above) && isLine(below) && !endsSpaced(above)) {
        failures.push({
          check: 'SPACE04',
          line: below.line,
          message: `${below.page}: ${label(below)} sits right under ${label(above)}, with no space` +
            ' between them' + add('top'),
        });
      }
    });
  }
  return failures.sort((a, b) => a.line - b.line);
}

module.exports = { verticalFindings };
