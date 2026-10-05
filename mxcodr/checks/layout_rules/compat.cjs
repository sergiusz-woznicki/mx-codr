// What check_layout's Node port needs from Python beyond ../py_compat.cjs: repr() of a str with
// Python's rules for what is printable, and reading a file the way Path.read_text(errors="replace")
// does (UTF-8 with replacement characters, universal newlines).
'use strict';
const fs = require('fs');

// str.isprintable() is false for these categories; the space itself is printable.
const UNPRINTABLE = /[\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}\p{Zl}\p{Zp}\p{Zs}]/u;

// repr(s) for a str.
function strRepr(s) {
  const quote = s.includes("'") && !s.includes('"') ? '"' : "'";
  let out = '';
  for (const c of s) {
    if (c === '\\') out += '\\\\';
    else if (c === quote) out += '\\' + c;
    else if (c === '\n') out += '\\n';
    else if (c === '\r') out += '\\r';
    else if (c === '\t') out += '\\t';
    else if (c !== ' ' && UNPRINTABLE.test(c)) {
      const cp = c.codePointAt(0);
      if (cp < 0x100) out += '\\x' + cp.toString(16).padStart(2, '0');
      else if (cp < 0x10000) out += '\\u' + cp.toString(16).padStart(4, '0');
      else out += '\\U' + cp.toString(16).padStart(8, '0');
    } else out += c;
  }
  return quote + out + quote;
}

// Path.read_text(encoding="utf-8", errors="replace").
function readTextReplace(file) {
  return fs.readFileSync(file).toString('utf8').replace(/\r\n?/g, '\n');
}

module.exports = { strRepr, readTextReplace };

// Shapes for the Python-named exports: what a dict, a set or a tuple-keyed dict becomes in JSON.
const asMap = x => (x instanceof Map ? x : new Map(Object.entries(x || {})));
const asSet = x => (x instanceof Set ? x : new Set(x || []));
// A Map with string keys as a plain object, values converted by fn.
function toObject(map, fn = v => v) {
  const out = {};
  for (const [k, v] of map) out[k] = fn(v);
  return out;
}
module.exports.asMap = asMap;
module.exports.asSet = asSet;
module.exports.toObject = toObject;
