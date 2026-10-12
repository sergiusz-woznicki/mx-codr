// LABEL01: a column caption or a field label that is an attribute name -- 'DueDate',
// 'OutstandingAmount', 'Invoice_Customer' -- instead of words. A column or input written without
// one gets the attribute's name, and the page shows it as is (InvoiceChaseReq, 2026-10-12: "DueDate",
// "CustomerName", "OpenInvoiceCount" on the owner's lists).
//
// Part of check_layout.cjs; see its header for inputs and the full rule table.
'use strict';
const py = require('../py_compat.cjs');
const { re } = py;
const { WIDGET_LINE_RE } = require('./pages.cjs');

const DOCUMENT_RE = re.compile(String.raw`^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(?:page|snippet)\s+(?P<name>[\w.]+)`, 'i');
const COLUMN_RE = re.compile(String.raw`^\s*column\s*\(`, 'i');
const TEXT_RE = /\b(Caption|Label)\s*:\s*'([^']*)'/g;
// An identifier, not words: no space, and a lower-then-upper join (DueDate) or an underscore.
const isIdentifier = text => !/\s/.test(text) && (/[a-z][A-Z]/.test(text) || /\w_\w/.test(text));
const words = text => text.replace(/_/g, ' ').replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
  .toLowerCase().replace(/^./, c => c.toUpperCase());

function rawLabelFindings(lines) {
  const failures = [];
  let document = '';
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    const found = DOCUMENT_RE.match(line);
    if (found) { document = found.group('name'); continue; }
    const widget = WIDGET_LINE_RE.match(line);
    const column = COLUMN_RE.match(line);
    if (!widget && !column) continue;
    // A layout grid column carries no caption; a data grid column and an input do.
    for (const m of line.matchAll(TEXT_RE)) {
      if (!isIdentifier(m[2])) continue;
      const what = column ? 'data grid column' : `${widget.group('type').toLowerCase()} ${widget.group('name')}`;
      failures.push({
        check: 'LABEL01',
        line: index + 1,
        message: `${document}: ${what} shows ${m[1]} '${m[2]}' -- an attribute's name, not words the user reads. ` +
          `Write ${m[1]}: '${words(m[2])}' (a ${m[1].toLowerCase()} left out takes the attribute's name)`,
      });
    }
  }
  return failures;
}

module.exports = { rawLabelFindings, isIdentifier };
