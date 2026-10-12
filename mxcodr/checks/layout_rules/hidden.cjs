// HIDDEN01: a widget that is never shown (`Visible: [false]`).
//
// A session met ISO01 ("a test signs in as the customer and reads CustomerContact") by adding a data
// grid of contacts with Visible: [false] to the customer's page, so its test could name it
// (InvoiceChaseReq, 2026-10-12). A widget no one can see is no feature, and a test that reads
// through it proves nothing about what the user is shown.
//
// Part of check_layout.cjs; see its header for inputs and the full rule table.
'use strict';
const py = require('../py_compat.cjs');
const { re } = py;
const { WIDGET_LINE_RE } = require('./pages.cjs');

const DOCUMENT_RE = re.compile(String.raw`^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(?:page|snippet)\s+(?P<name>[\w.]+)`, 'i');
// A constant false only: `Visible: [$currentObject/IsPaid = false]` is a real condition.
const NEVER_VISIBLE_RE = re.compile(String.raw`\bVisible\s*:\s*(\[\s*false\s*\]|false\b)`, 'i');

function hiddenWidgetFindings(lines) {
  const failures = [];
  let document = '';
  for (let index = 0; index < lines.length; index++) {
    const found = DOCUMENT_RE.match(lines[index]);
    if (found) { document = found.group('name'); continue; }
    const widget = WIDGET_LINE_RE.match(lines[index]);
    if (!widget) continue;
    // The widget's properties run to the line that opens its body or closes them.
    let header = lines[index], look = index;
    while (look < lines.length - 1) {
      const r = py.rstrip(lines[look]);
      if (r.endsWith('{') || r.endsWith(')') || r.endsWith(';')) break;
      look++;
      header += ' ' + lines[look];
    }
    if (!NEVER_VISIBLE_RE.search(header)) continue;
    failures.push({
      check: 'HIDDEN01',
      line: index + 1,
      message: `${document}: ${widget.group('type').toLowerCase()} ${widget.group('name')} is never shown (Visible: [false]) -- ` +
        'a widget no one can see is no feature, and a test that reads through it proves nothing. Remove it. ' +
        "To prove what a role may read, read it as that user in the test (oql_count with the other user's key = 0); " +
        'to show it, put it where the user needs it with a real condition, or none',
    });
  }
  return failures;
}

module.exports = { hiddenWidgetFindings };
