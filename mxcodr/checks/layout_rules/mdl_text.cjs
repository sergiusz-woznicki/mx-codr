// layout_rules/mdl_text.cjs -- reading the text of a described page: the helpers several rules need.
'use strict';
const py = require('../py_compat.cjs');

// A quoted MDL string, with '' for a quote inside it.
const QUOTED = /'(?:[^']|'')*'/g;

// How often `sub` occurs in `s`.
const count = (s, sub) => s.split(sub).length - 1;

// Braces that open or close a block: not inside a quoted caption, not `{1}` of ContentParams.
function depthChange(line) {
  const bare = line.replace(QUOTED, "''").replace(/\{\d+\}/g, '');
  return count(bare, '{') - count(bare, '}');
}

// A widget's properties: its line, and the lines below while it is still open with `(`.
function propsOf(lines, index) {
  let props = lines[index];
  if (/\(\s*$/.test(props)) {
    for (let look = index + 1; look < lines.length && !/^\s*\)/.test(lines[look]); look++) props += ' ' + py.strip(lines[look]);
  }
  return props;
}

module.exports = { QUOTED, count, depthChange, propsOf };
