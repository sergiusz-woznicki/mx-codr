// The parts of Python's standard library the checks were written against, for their Node ports.
//
// The checks moved from Python to Node (2026-10-05) with the rule that a port prints exactly what
// the Python did, on every platform. Where the two runtimes differ -- regular expressions (Unicode
// \w, \b, \s; `$` before a final newline), shlex, glob, json.dumps, str.split()/strip()/splitlines(),
// text-mode reads that turn \r\n into \n -- the port calls this module instead of the JS built-in.
'use strict';
const fs = require('fs');
const path = require('path');

const WIN = process.platform === 'win32';

// ---- strings ----

// str.isspace(): bidi WS/B/S or category Zs.
const SPACE_CHARS = '\\t\\n\\x0b\\x0c\\r\\x1c-\\x20\\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000';
const SPACE = new RegExp('[' + SPACE_CHARS + ']', 'u');
const isSpace = c => SPACE.test(c);

function strip(s, chars) {
  return rstrip(lstrip(s, chars), chars);
}
function lstrip(s, chars) {
  let a = 0;
  const test = chars == null ? isSpace : c => chars.includes(c);
  while (a < s.length && test(s[a])) a++;
  return s.slice(a);
}
function rstrip(s, chars) {
  let b = s.length;
  const test = chars == null ? isSpace : c => chars.includes(c);
  while (b > 0 && test(s[b - 1])) b--;
  return s.slice(0, b);
}

// str.split() with no separator: runs of whitespace, no empty strings. With a separator and a
// maxsplit, Python keeps the rest in the last item (JS drops it).
function split(s, sep, maxsplit = -1) {
  if (sep == null) {
    const out = [];
    let i = 0;
    while (i < s.length) {
      while (i < s.length && isSpace(s[i])) i++;
      if (i >= s.length) break;
      if (maxsplit >= 0 && out.length === maxsplit) { out.push(rstrip(s.slice(i))); break; }
      let j = i;
      while (j < s.length && !isSpace(s[j])) j++;
      out.push(s.slice(i, j));
      i = j;
    }
    return out;
  }
  const parts = s.split(sep);
  if (maxsplit < 0 || parts.length <= maxsplit + 1) return parts;
  return [...parts.slice(0, maxsplit), parts.slice(maxsplit).join(sep)];
}
function rsplit(s, sep, maxsplit = -1) {
  const parts = s.split(sep);
  if (maxsplit < 0 || parts.length <= maxsplit + 1) return parts;
  return [parts.slice(0, parts.length - maxsplit).join(sep), ...parts.slice(parts.length - maxsplit)];
}

// str.splitlines(): every line boundary Python knows, no trailing empty line.
function splitlines(s, keepends = false) {
  const out = [];
  const re = /\r\n|[\n\r\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029]/g;
  let at = 0, m;
  while ((m = re.exec(s))) {
    out.push(s.slice(at, keepends ? m.index + m[0].length : m.index));
    at = m.index + m[0].length;
  }
  if (at < s.length) out.push(s.slice(at));
  return out;
}

// open(path).read() in text mode: \r\n and \r become \n (universal newlines).
function readText(file) {
  return fs.readFileSync(file, 'utf8').replace(/\r\n?/g, '\n');
}
// sys.stdin.read(): CPython reads stdin with universal newlines on Windows only (newline=None
// there, "\n" elsewhere). An empty or closed stdin reads as ''.
function readStdin() {
  let text;
  try {
    text = fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
  return WIN ? text.replace(/\r\n?/g, '\n') : text;
}
// sys.stdin.buffer.read(): the raw bytes.
function readStdinBytes() {
  try {
    return fs.readFileSync(0);
  } catch {
    return Buffer.alloc(0);
  }
}

// str(value) for the JSON values a check prints.
function pyStr(value) {
  if (value === null || value === undefined) return 'None';
  if (value === true) return 'True';
  if (value === false) return 'False';
  if (typeof value === 'number') return pyNumber(value);
  if (typeof value === 'string') return value;
  return pyRepr(value);
}
function pyNumber(n) {
  if (Number.isInteger(n) && !Object.is(n, -0) && Math.abs(n) < 1e16) return String(n);
  if (Number.isInteger(n)) return Math.abs(n) < 1e16 ? n.toFixed(1) : String(n).replace('e+', 'e+');
  return String(n);
}
function pyRepr(value) {
  if (typeof value === 'string') {
    const quote = value.includes("'") && !value.includes('"') ? '"' : "'";
    let out = '';
    for (const c of value) {
      if (c === '\\') out += '\\\\';
      else if (c === quote) out += '\\' + c;
      else if (c === '\n') out += '\\n';
      else if (c === '\r') out += '\\r';
      else if (c === '\t') out += '\\t';
      else if (c < ' ' || c === '\x7f') out += '\\x' + c.charCodeAt(0).toString(16).padStart(2, '0');
      else out += c;
    }
    return quote + out + quote;
  }
  if (Array.isArray(value)) return '[' + value.map(pyRepr).join(', ') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.entries(value).map(([k, v]) => pyRepr(k) + ': ' + pyRepr(v)).join(', ') + '}';
  }
  return pyStr(value);
}

// json.dumps with Python's defaults: ensure_ascii, separators (', ', ': ') or (',', ': ') with an
// indent, sort_keys on request.
function jsonDumps(value, { indent = null, sortKeys = false, ensureAscii = true, separators = null } = {}) {
  const [itemSep, keySep] = separators || (indent == null ? [', ', ': '] : [',', ': ']);
  const pad = typeof indent === 'number' ? ' '.repeat(indent) : indent;
  const str = s => {
    let out = JSON.stringify(s);
    if (ensureAscii) out = out.replace(/[\u007f-￿]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
    return out;
  };
  const enc = (v, level) => {
    if (v === null || v === undefined) return 'null';
    if (v === true) return 'true';
    if (v === false) return 'false';
    if (typeof v === 'number') {
      if (Number.isNaN(v)) return 'NaN';
      if (!Number.isFinite(v)) return v > 0 ? 'Infinity' : '-Infinity';
      return pyNumber(v);
    }
    if (typeof v === 'string') return str(v);
    const inner = pad == null ? '' : '\n' + pad.repeat(level + 1);
    const outer = pad == null ? '' : '\n' + pad.repeat(level);
    if (Array.isArray(v)) {
      if (!v.length) return '[]';
      return '[' + inner + v.map(x => enc(x, level + 1)).join(itemSep + inner) + outer + ']';
    }
    let keys = Object.keys(v);
    if (!keys.length) return '{}';
    if (sortKeys) keys = keys.sort(compare);
    return '{' + inner + keys.map(k => str(k) + keySep + enc(v[k], level + 1)).join(itemSep + inner) + outer + '}';
  };
  return enc(value, 0);
}

// Python's string order (by code point), for sort comparators.
function compare(a, b) {
  if (a === b) return 0;
  const x = [...a], y = [...b];
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    if (x[i] !== y[i]) return x[i].codePointAt(0) - y[i].codePointAt(0);
  }
  return x.length - y.length;
}
// Tuple order: compare item by item (numbers as numbers, strings by code point).
function compareTuples(a, b) {
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    const x = a[i], y = b[i];
    if (x === y) continue;
    if (Array.isArray(x)) { const c = compareTuples(x, y); if (c) return c; continue; }
    if (typeof x === 'number') return x < y ? -1 : x > y ? 1 : 0;
    if (typeof x === 'boolean') return (x ? 1 : 0) - (y ? 1 : 0);
    const c = compare(String(x), String(y));
    if (c) return c;
  }
  return a.length - b.length;
}
// sorted(items, key=..., reverse=...): stable, like Python's.
function sorted(items, key = null, reverse = false) {
  const decorated = [...items].map((item, i) => [key ? key(item) : item, i, item]);
  decorated.sort((p, q) => {
    const c = cmpAny(p[0], q[0]);
    return (reverse ? -c : c) || p[1] - q[1];
  });
  return decorated.map(d => d[2]);
}
function cmpAny(x, y) {
  if (Array.isArray(x)) return compareTuples(x, y);
  if (typeof x === 'number' || typeof x === 'boolean') return x < y ? -1 : x > y ? 1 : 0;
  return compare(String(x), String(y));
}

// ---- regular expressions with Python's meaning ----

const WORD = '\\p{L}\\p{N}_';             // \w for str patterns: str.isalnum() or '_'
const DIGIT = '\\p{Nd}';                   // \d
const SYNTAX = '^$\\.*+?()[]{}|/';
const cache = new Map();

// Translate a Python pattern to an equivalent JS one (flag u, never m or s: anchors and `.` are
// written out). Flags: a string of Python flag letters (i, m, s, x).
function translate(source, flags = '') {
  let i = 0;
  let pyFlags = flags;
  // Leading inline flags, (?im) and the like.
  for (let m; (m = /^\(\?([aiLmsux]+)\)/.exec(source.slice(i)));) { pyFlags += m[1]; i += m[0].length; }
  const multiline = pyFlags.includes('m'), dotall = pyFlags.includes('s'), verbose = pyFlags.includes('x');
  let out = '';
  const n = source.length;
  const NOT_WORD_AHEAD = `(?![${WORD}])`, WORD_AHEAD = `(?=[${WORD}])`;
  const NOT_WORD_BEHIND = `(?<![${WORD}])`, WORD_BEHIND = `(?<=[${WORD}])`;
  const classEscape = c => {
    switch (c) {
      case 'w': return WORD;
      case 'd': return DIGIT;
      case 's': return SPACE_CHARS;
      case 'W': case 'D': case 'S': throw new Error('negated class escape inside a set: \\' + c);
      default: return null;
    }
  };
  while (i < n) {
    const c = source[i];
    if (verbose && isSpace(c)) { i++; continue; }
    if (verbose && c === '#') { while (i < n && source[i] !== '\n') i++; continue; }
    if (c === '\\') {
      const e = source[i + 1];
      i += 2;
      if (e === 'w') out += `[${WORD}]`;
      else if (e === 'W') out += `[^${WORD}]`;
      else if (e === 'd') out += `[${DIGIT}]`;
      else if (e === 'D') out += `[^${DIGIT}]`;
      else if (e === 's') out += `[${SPACE_CHARS}]`;
      else if (e === 'S') out += `[^${SPACE_CHARS}]`;
      else if (e === 'b') out += `(?:${NOT_WORD_BEHIND}${WORD_AHEAD}|${WORD_BEHIND}${NOT_WORD_AHEAD})`;
      else if (e === 'B') out += `(?:${WORD_BEHIND}${WORD_AHEAD}|${NOT_WORD_BEHIND}${NOT_WORD_AHEAD})`;
      else if (e === 'A') out += '^';
      else if (e === 'Z') out += '$';
      else if (e === 'x') { out += '\\x' + source.slice(i, i + 2); i += 2; }
      else if (e === 'u') { out += '\\u' + source.slice(i, i + 4); i += 4; }
      else if (/[0-9]/.test(e)) {
        let num = e;
        while (i < n && /[0-9]/.test(source[i]) && num.length < 2) num += source[i++];
        out += '\\' + num;
      } else if ('nrtfv'.includes(e)) out += '\\' + e;
      else if (e === 'a') out += '\\x07';
      else if (SYNTAX.includes(e)) out += '\\' + e;
      else out += e.replace(/[\s\S]/u, ch => (SYNTAX.includes(ch) ? '\\' + ch : ch));
      continue;
    }
    if (c === '[') {
      // A set: copy it, translating escapes; a leading ] is literal in Python.
      let j = i + 1, set = '[';
      if (source[j] === '^') { set += '^'; j++; }
      if (source[j] === ']') { set += '\\]'; j++; }
      while (j < n && source[j] !== ']') {
        const d = source[j];
        if (d === '\\') {
          const e = source[j + 1];
          const cls = classEscape(e);
          if (cls) set += cls;
          else if (e === 'x') { set += '\\x' + source.slice(j + 2, j + 4); j += 2; }
          else if (e === 'u') { set += '\\u' + source.slice(j + 2, j + 6); j += 4; }
          else if ('nrtfv'.includes(e)) set += '\\' + e;
          else if (/[\w]/.test(e) && !/[0-9]/.test(e)) set += e;
          // Flag u allows only syntax characters and - to be escaped in a set; the rest are literal.
          else if (SYNTAX.includes(e) || e === '-') set += '\\' + e;
          else set += e;
          j += 2;
          continue;
        }
        if (d === '[' || d === '/' || d === '{' || d === '}' || d === '(' || d === ')' || d === '|') set += '\\' + d;
        else set += d;
        j++;
      }
      out += set + ']';
      i = j + 1;
      continue;
    }
    if (c === '(' && source[i + 1] === '?') {
      if (source[i + 2] === 'P' && source[i + 3] === '<') { out += '(?<'; i += 4; continue; }
      if (source[i + 2] === 'P' && source[i + 3] === '=') {
        const close = source.indexOf(')', i);
        out += '\\k<' + source.slice(i + 4, close) + '>';
        i = close + 1;
        continue;
      }
      if (source[i + 2] === '#') { i = source.indexOf(')', i) + 1; continue; }
    }
    if (c === '{') {
      const m = /^\{(\d*)(,?)(\d*)\}/.exec(source.slice(i));
      if (m && (m[1] || m[3])) { out += '{' + (m[1] || '0') + m[2] + m[3] + '}'; i += m[0].length; continue; }
      out += '\\{'; i++; continue;
    }
    if (c === '}') { out += '\\}'; i++; continue; }
    if (c === '.') { out += dotall ? '[\\s\\S]' : '[^\\n]'; i++; continue; }
    if (c === '^') { out += multiline ? '(?<![^\\n])' : '^'; i++; continue; }
    if (c === '$') { out += multiline ? '(?=\\n|$)' : '(?=\\n?$)'; i++; continue; }
    if (c === '/') { out += '\\/'; i++; continue; }
    out += c;
    i++;
  }
  return { source: out, ignoreCase: pyFlags.includes('i') };
}

class Pattern {
  constructor(source, flags = '') {
    const t = translate(source, flags);
    this.pattern = source;
    this.js = t.source;
    this.jsFlags = 'du' + (t.ignoreCase ? 'i' : '');
    this.re = new RegExp(this.js, this.jsFlags + 'g');
    this.sticky = new RegExp(this.js, this.jsFlags + 'y');
  }
  search(s, pos = 0) {
    this.re.lastIndex = pos;
    return wrap(this.re.exec(s));
  }
  match(s, pos = 0) {
    this.sticky.lastIndex = pos;
    return wrap(this.sticky.exec(s));
  }
  fullmatch(s) {
    const re = new RegExp('(?:' + this.js + ')$', this.jsFlags + 'y');
    re.lastIndex = 0;
    return wrap(re.exec(s));
  }
  *finditer(s) {
    const re = new RegExp(this.js, this.jsFlags + 'g');
    let m;
    while ((m = re.exec(s))) {
      yield wrap(m);
      if (m[0] === '') re.lastIndex += s.codePointAt(m.index) > 0xffff ? 2 : 1;
    }
  }
  findall(s) {
    const out = [];
    for (const m of this.finditer(s)) {
      const groups = m.raw.length - 1;
      if (groups === 0) out.push(m.group(0));
      else if (groups === 1) out.push(m.group(1) ?? '');
      else out.push(m.groups().map(g => g ?? ''));
    }
    return out;
  }
  sub(repl, s, count = 0) {
    let out = '', at = 0, done = 0;
    for (const m of this.finditer(s)) {
      if (count && done >= count) break;
      out += s.slice(at, m.start()) + (typeof repl === 'function' ? repl(m) : expand(repl, m));
      at = m.end();
      done++;
    }
    return out + s.slice(at);
  }
  split(s, maxsplit = 0) {
    const out = [];
    let at = 0, done = 0;
    for (const m of this.finditer(s)) {
      if (maxsplit && done >= maxsplit) break;
      out.push(s.slice(at, m.start()), ...m.raw.slice(1).map(g => (g === undefined ? null : g)));
      at = m.end();
      done++;
    }
    out.push(s.slice(at));
    return out;
  }
}

// The replacement template of re.sub: \1, \g<1>, \g<name>, \n and friends.
function expand(template, m) {
  return template.replace(/\\(g<([^>]+)>|\d{1,2}|[nrt\\])/g, (all, what, name) => {
    if (name !== undefined) return (/^\d+$/.test(name) ? m.group(Number(name)) : m.group(name)) ?? '';
    if (/^\d/.test(what)) return m.group(Number(what)) ?? '';
    return { n: '\n', r: '\r', t: '\t', '\\': '\\' }[what];
  });
}

class Match {
  constructor(raw) { this.raw = raw; }
  group(...which) {
    if (which.length > 1) return which.map(w => this.group(w));
    const w = which.length ? which[0] : 0;
    const v = typeof w === 'number' ? this.raw[w] : (this.raw.groups || {})[w];
    return v === undefined ? null : v;
  }
  groups(dflt = null) { return this.raw.slice(1).map(g => (g === undefined ? dflt : g)); }
  groupdict() {
    const out = {};
    for (const [k, v] of Object.entries(this.raw.groups || {})) out[k] = v === undefined ? null : v;
    return out;
  }
  span(g = 0) {
    const at = typeof g === 'number' ? this.raw.indices[g] : (this.raw.indices.groups || {})[g];
    return at ? [at[0], at[1]] : [-1, -1];
  }
  start(g = 0) { return this.span(g)[0]; }
  end(g = 0) { return this.span(g)[1]; }
  get string() { return this.raw.input; }
}
const wrap = raw => (raw ? new Match(raw) : null);

function compile(source, flags = '') {
  const key = flags + '\0' + source;
  let p = cache.get(key);
  if (!p) { p = new Pattern(source, flags); cache.set(key, p); }
  return p;
}
const re = {
  compile,
  search: (p, s, f = '') => compile(p, f).search(s),
  match: (p, s, f = '') => compile(p, f).match(s),
  fullmatch: (p, s, f = '') => compile(p, f).fullmatch(s),
  findall: (p, s, f = '') => compile(p, f).findall(s),
  finditer: (p, s, f = '') => compile(p, f).finditer(s),
  sub: (p, r, s, count = 0, f = '') => compile(p, f).sub(r, s, count),
  split: (p, s, maxsplit = 0, f = '') => compile(p, f).split(s, maxsplit),
  // re.escape since Python 3.7: only the characters with a meaning in a pattern.
  escape: s => s.replace(/[()[\]{}?*+\-|^$\\.&~# \t\n\r\v\f]/g, c => '\\' + c),
};

// ---- shlex, posix mode ----
class Shlex {
  constructor(text, punctuationChars) {
    this.text = text;
    this.at = 0;
    this.commenters = '#';
    this.wordchars = 'abcdfeghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_' +
      'ßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞ';
    this.whitespace = ' \t\r\n';
    this.whitespaceSplit = false;
    this.quotes = '\'"';
    this.escape = '\\';
    this.escapedquotes = '"';
    this.state = ' ';
    this.token = '';
    this.punctuation = punctuationChars === true ? '();<>|&' : (punctuationChars || '');
    this.pushbackChars = [];
    if (this.punctuation) {
      this.wordchars += '~-./*?=';
      this.wordchars = [...this.wordchars].filter(c => !this.punctuation.includes(c)).join('');
    }
  }
  read() {
    if (this.at >= this.text.length) return '';
    const c = String.fromCodePoint(this.text.codePointAt(this.at));
    this.at += c.length;
    return c;
  }
  readline() {
    const nl = this.text.indexOf('\n', this.at);
    this.at = nl < 0 ? this.text.length : nl + 1;
  }
  readToken() {
    const has = (set, c) => set.includes(c);
    let quoted = false;
    let escapedstate = ' ';
    for (;;) {
      const nextchar = this.punctuation && this.pushbackChars.length ? this.pushbackChars.pop() : this.read();
      if (this.state === null) {
        this.token = '';
        break;
      } else if (this.state === ' ') {
        if (!nextchar) { this.state = null; break; }
        else if (has(this.whitespace, nextchar)) {
          if (this.token || quoted) break;
          continue;
        } else if (has(this.commenters, nextchar)) {
          this.readline();
        } else if (has(this.escape, nextchar)) {
          escapedstate = 'a';
          this.state = nextchar;
        } else if (has(this.wordchars, nextchar)) {
          this.token = nextchar; this.state = 'a';
        } else if (has(this.punctuation, nextchar)) {
          this.token = nextchar; this.state = 'c';
        } else if (has(this.quotes, nextchar)) {
          this.state = nextchar;
        } else if (this.whitespaceSplit) {
          this.token = nextchar; this.state = 'a';
        } else {
          this.token = nextchar;
          if (this.token || quoted) break;
          continue;
        }
      } else if (has(this.quotes, this.state)) {
        quoted = true;
        if (!nextchar) throw new Error('No closing quotation');
        if (nextchar === this.state) {
          this.state = 'a';
        } else if (has(this.escape, nextchar) && has(this.escapedquotes, this.state)) {
          escapedstate = this.state;
          this.state = nextchar;
        } else {
          this.token += nextchar;
        }
      } else if (has(this.escape, this.state)) {
        if (!nextchar) throw new Error('No escaped character');
        if (has(this.quotes, escapedstate) && nextchar !== this.state && nextchar !== escapedstate) {
          this.token += this.state;
        }
        this.token += nextchar;
        this.state = escapedstate;
      } else if (this.state === 'a' || this.state === 'c') {
        if (!nextchar) { this.state = null; break; }
        else if (has(this.whitespace, nextchar)) {
          this.state = ' ';
          if (this.token || quoted) break;
          continue;
        } else if (has(this.commenters, nextchar)) {
          this.readline();
          this.state = ' ';
          if (this.token || quoted) break;
          continue;
        } else if (this.state === 'c') {
          if (has(this.punctuation, nextchar)) {
            this.token += nextchar;
          } else {
            if (!has(this.whitespace, nextchar)) this.pushbackChars.push(nextchar);
            this.state = ' ';
            break;
          }
        } else if (has(this.quotes, nextchar)) {
          this.state = nextchar;
        } else if (has(this.escape, nextchar)) {
          escapedstate = 'a';
          this.state = nextchar;
        } else if (has(this.wordchars, nextchar) || has(this.quotes, nextchar) ||
                   (this.whitespaceSplit && !has(this.punctuation, nextchar))) {
          this.token += nextchar;
        } else {
          this.pushbackChars.push(nextchar);
          this.state = ' ';
          if (this.token || quoted) break;
          continue;
        }
      }
    }
    let result = this.token;
    this.token = '';
    if (!quoted && result === '') result = null;
    return result;
  }
  all() {
    const out = [];
    for (let tok = this.readToken(); tok !== null; tok = this.readToken()) out.push(tok);
    return out;
  }
}
// shlex.split(text): throws on an unclosed quote or a trailing backslash, as Python's ValueError.
function shlexSplit(text) {
  const lex = new Shlex(text, '');
  lex.whitespaceSplit = true;
  lex.commenters = '';
  return lex.all();
}

// ---- os.path and glob ----

function basename(p) {
  if (WIN) return p.replace(/^[A-Za-z]:/, '').split(/[\\/]/).pop();
  return p.slice(p.lastIndexOf('/') + 1);
}
function dirname(p) {
  // os.path.dirname: everything before the last separator, trailing separators dropped unless
  // that would leave nothing but the root.
  let drive = '';
  if (WIN && /^[A-Za-z]:/.test(p)) { drive = p.slice(0, 2); p = p.slice(2); }
  const i = Math.max(p.lastIndexOf('/'), WIN ? p.lastIndexOf('\\') : -1) + 1;
  let head = p.slice(0, i);
  const trimmed = head.replace(WIN ? /[\\/]+$/ : /\/+$/, '');
  if (trimmed) head = trimmed;
  return drive + head;
}
function join(a, ...rest) {
  const sep = WIN ? '\\' : '/';
  let out = a;
  for (const b of rest) {
    if (b.startsWith('/') || (WIN && (/^[A-Za-z]:/.test(b) || b.startsWith('\\')))) { out = b; continue; }
    if (!out || out.endsWith('/') || (WIN && (out.endsWith('\\') || /^[A-Za-z]:$/.test(out)))) out += b;
    else out += sep + b;
  }
  return out;
}
function exists(p) { try { fs.statSync(p); return true; } catch { return false; } }
function lexists(p) { try { fs.lstatSync(p); return true; } catch { return false; } }
function isdir(p) { try { return fs.statSync(p).isDirectory(); } catch { return false; } }
function isfile(p) { try { return fs.statSync(p).isFile(); } catch { return false; } }

const MAGIC = /[*?[]/;
// fnmatch.translate for one path component, as Python 3.11 has it (reversed ranges in a set are
// dropped, not an error); Windows compares case-insensitively (normcase).
function fnmatchRegex(pat) {
  const res = [];
  const STAR = {};
  let i = 0;
  const n = pat.length;
  const esc = c => c.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
  while (i < n) {
    const c = pat[i++];
    if (c === '*') {
      if (!res.length || res[res.length - 1] !== STAR) res.push(STAR);
    } else if (c === '?') res.push('[\\s\\S]');
    else if (c === '[') {
      let j = i;
      if (j < n && pat[j] === '!') j++;
      if (j < n && pat[j] === ']') j++;
      while (j < n && pat[j] !== ']') j++;
      if (j >= n) { res.push('\\['); continue; }
      let stuff = pat.slice(i, j);
      if (!stuff.includes('-')) {
        stuff = stuff.replace(/\\/g, '\\\\');
      } else {
        const chunks = [];
        let k = pat[i] === '!' ? i + 2 : i + 1;
        for (;;) {
          k = pat.indexOf('-', k);
          if (k < 0 || k >= j) break;
          chunks.push(pat.slice(i, k));
          i = k + 1;
          k += 3;
        }
        const chunk = pat.slice(i, j);
        if (chunk) chunks.push(chunk);
        else chunks[chunks.length - 1] += '-';
        // Remove empty ranges -- invalid in RE.
        for (let m = chunks.length - 1; m > 0; m--) {
          const prev = chunks[m - 1], cur = chunks[m];
          if (prev[prev.length - 1] > cur[0]) {
            chunks[m - 1] = prev.slice(0, -1) + cur.slice(1);
            chunks.splice(m, 1);
          }
        }
        stuff = chunks.map(x => x.replace(/\\/g, '\\\\').replace(/-/g, '\\-')).join('-');
      }
      i = j + 1;
      if (!stuff) res.push('(?!)');
      else if (stuff === '!') res.push('[\\s\\S]');
      else {
        if (stuff[0] === '!') stuff = '^' + stuff.slice(1);
        else if (stuff[0] === '^' || stuff[0] === '[') stuff = '\\' + stuff;
        // A ] that Python reads as a member closes a JS set; [ is literal in both.
        res.push('[' + stuff.replace(/(^\^?)\]/, '$1\\]') + ']');
      }
    } else res.push(esc(c));
  }
  const body = res.map(x => (x === STAR ? '[\\s\\S]*' : x)).join('');
  try {
    return new RegExp('^(?:' + body + ')$', WIN ? 'iu' : 'u');
  } catch {
    return new RegExp('^(?:' + body + ')$', WIN ? 'i' : '');
  }
}
// glob.glob(pattern), unsorted as Python returns it (callers sort).
function glob(pattern) {
  return [...iglob(pattern)];
}
function* iglob(pattern) {
  const dirnameOf = p => {
    const i = Math.max(p.lastIndexOf('/'), WIN ? p.lastIndexOf('\\') : -1);
    if (i < 0) return ['', p];
    let head = p.slice(0, i + 1);
    const trimmed = head.replace(WIN ? /[\\/]+$/ : /\/+$/, '');
    if (trimmed && !(WIN && /^[A-Za-z]:$/.test(trimmed))) head = trimmed;
    return [head, p.slice(i + 1)];
  };
  const [dir, base] = dirnameOf(pattern);
  if (!MAGIC.test(pattern)) {
    if (base ? lexists(pattern) : isdir(dir)) yield pattern;
    return;
  }
  if (!dir) { yield* glob1('', base); return; }
  const dirs = dir !== pattern && MAGIC.test(dir) ? iglob(dir) : [dir];
  const one = MAGIC.test(base) ? glob1 : glob0;
  for (const d of dirs) for (const name of one(d, base)) yield join(d, name);
}
function* glob1(dir, pattern) {
  let names;
  try {
    names = fs.readdirSync(dir || '.');
  } catch {
    return;
  }
  if (!pattern.startsWith('.')) names = names.filter(n => !n.startsWith('.'));
  const rx = fnmatchRegex(pattern);
  for (const n of names) if (rx.test(n)) yield n;
}
function* glob0(dir, base) {
  if (!base) { if (isdir(dir)) yield base; }
  else if (lexists(join(dir, base))) yield base;
}

function normpath(p) {
  if (WIN) p = p.replace(/\\/g, '/');
  if (p === '') return '.';
  let drive = '';
  if (WIN && /^[A-Za-z]:/.test(p)) { drive = p.slice(0, 2); p = p.slice(2); }
  let initial = p.startsWith('/') ? 1 : 0;
  if (!WIN && initial && p.startsWith('//') && !p.startsWith('///')) initial = 2;
  const parts = [];
  for (const comp of p.split('/')) {
    if (comp === '' || comp === '.') continue;
    if (comp !== '..' || (!initial && !parts.length) || (parts.length && parts[parts.length - 1] === '..')) parts.push(comp);
    else if (parts.length) parts.pop();
  }
  let out = '/'.repeat(initial) + parts.join('/');
  if (WIN) out = (drive + out).replace(/\//g, '\\');
  return out || '.';
}

// sys.stdout.write / print(): synchronous, \n also on Windows (Python wrote \r\n there, which
// leaked a \r into every value a shell read back).
function write(text) {
  const buf = Buffer.from(text, 'utf8');
  let at = 0;
  while (at < buf.length) {
    try {
      at += fs.writeSync(1, buf, at);
    } catch (error) {
      if (error.code !== 'EAGAIN') throw error;
    }
  }
}
function print(...items) { write(items.map(pyStr).join(' ') + '\n'); }

module.exports = {
  WIN, strip, lstrip, rstrip, split, rsplit, splitlines, isSpace, readText, readStdin, readStdinBytes,
  pyStr, pyRepr, jsonDumps, compare, compareTuples, sorted, re, translate, Shlex, shlexSplit,
  basename, dirname, join, exists, lexists, isdir, isfile, glob, iglob, fnmatchRegex, normpath, print, write,
};
