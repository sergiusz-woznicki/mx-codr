// DATE01: a data grid column shows a DateTime as a date only, while the app's own form edits the
// time of day of that attribute.
//
// Part of check_layout.cjs; see its header for inputs and the full rule table.
//
// Data grid 2 formats a DateTime attribute with the date format alone. A booking from 10:00 to
// 11:00 then shows as "10/13/2026 | 10/13/2026" -- the slot is gone (room-booking run, 2026-10-13).
// Whether the time matters is the app's own word: a datepicker with DateFormat: DateTime or Time,
// or a CustomDateFormat with hours or minutes in it ('dd-MM-yyyy HH:mm', room-booking r3), edits it. Every grid column bound to such an attribute then shows the time too, as a dynamic
// text; the column keeps its Attribute, so it still sorts and filters.
'use strict';
const py = require('../py_compat.cjs');

const DOCUMENT = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(?:page|snippet)\s+([\w.]+)/i;
const DATEPICKER = /^\s*datepicker\s+("[^"]*"|[\w.]+)\s*\(/i;
const COLUMN = /^\s*column\b(?:\s+("[^"]*"|\w+))?\s*\(/i;
// `Attribute: StartsAt`, `Attribute: "StartsAt"`, `Attribute: Booking_Slot/StartsAt`: the last segment.
const ATTRIBUTE = /\bAttribute:\s*((?:"?\w+"?\/)*)"?(\w+)"?(?![\w/.])/;
const WITH_TIME = /\bDateFormat:\s*(DateTime|Time)\b/i;
const CUSTOM = /\bCustomDateFormat:\s*'((?:[^']|'')*)'/i;
// Hours (H h k K), minutes (m) or AM/PM (a) outside quoted literal text.
const TIME_LETTERS = /[HhkKma]/;
const SHOWN_AS = /\bShowContentAs:\s*(dynamicText|customContent)\b/i;

// A widget's properties: its line, and the lines below while it is still open with `(`.
function propsOf(lines, index) {
  let props = lines[index];
  if (/\(\s*$/.test(props)) {
    for (let look = index + 1; look < lines.length && !/^\s*\)/.test(lines[look]); look++) props += ' ' + py.strip(lines[look]);
  }
  return props;
}

// [failures, warnings] for the pages and snippets in <lines>.
function dateColumnFindings(lines) {
  const timed = Object.create(null);
  lines.forEach((line, index) => {
    if (!DATEPICKER.test(line)) return;
    const props = propsOf(lines, index);
    const attr = ATTRIBUTE.exec(props);
    const format = WITH_TIME.exec(props);
    const custom = CUSTOM.exec(props);
    if (attr && format) timed[attr[2]] = { shown: 'DateFormat: ' + format[1], pattern: /^time$/i.test(format[1]) ? 'HH:mm' : 'd MMM yyyy, HH:mm' };
    else if (attr && custom && TIME_LETTERS.test(custom[1].replace(/''/g, '').replace(/'[^']*'/g, ''))) {
      timed[attr[2]] = { shown: `CustomDateFormat: '${custom[1]}'`, pattern: custom[1] };
    }
  });
  const failures = [];
  if (!Object.keys(timed).length) return [failures, []];
  let documentName = '';
  lines.forEach((line, index) => {
    const head = DOCUMENT.exec(line);
    if (head) documentName = head[1];
    if (!COLUMN.test(line)) return;
    const props = propsOf(lines, index);
    const attr = ATTRIBUTE.exec(props);
    if (!attr || !(attr[2] in timed) || SHOWN_AS.test(props)) return;
    const path = attr[1].split('"').join('') + attr[2];
    const { shown, pattern } = timed[attr[2]];
    failures.push({
      check: 'DATE01',
      line: index + 1,
      message: `${documentName}: the data grid column on ${path} shows the date only, but a form edits its time` +
        ` (${shown}) -- the time a person picked is not on screen. Keep the Attribute and add` +
        ` ShowContentAs: dynamicText, Content: '{1}', ContentParams: ({1} = formatDateTime($currentObject/${path}, '${pattern}'))` +
        ' to the column (the $currentObject/ path is required: a bare attribute is CE0117).',
    });
  });
  return [failures, []];
}

module.exports = { dateColumnFindings };
