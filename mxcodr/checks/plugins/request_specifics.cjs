/**
 * checks/plugins/request_specifics.cjs -- what a request spells out, and whether the plan kept it.
 * Self-contained (no parent requires), like request_archive.cjs and capture_guard.cjs, because the plugins
 * load it from the bundle or from an installed project; the gate's REQ04 and the capture guard both use it.
 *
 * A request names hard details: a count ("10 digits", "last 6 months"), a quoted caption, a format
 * (DD/MM/YYYY), a bound (>0), a placement or state ("above the table", "disabled"). The requirements an
 * agent writes are paraphrases, one line each, and the details fall out of the paraphrase: nothing tested
 * them, the gate said DONE, and a run that was told "implement literally, do not simplify" shipped without
 * them (b2b-orders hb1, 2026-10-25). A specific is KEPT when a requirement or an assumption of the plan
 * repeats it; the checks are language-light on purpose: numbers, quotes, format tokens, comparison
 * symbols and a short list of cue words. Nothing in here knows an application.
 */

const { existsSync, readFileSync, readdirSync } = require("node:fs")
const { join } = require("node:path")

const NUMBER_WORDS = { two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12 }
const WORD_OF = Object.fromEntries(Object.entries(NUMBER_WORDS).map(([w, n]) => [String(n), w]))
// Words that state a constraint, a state or a place; the plan must repeat the word.
const CUES = [
  ["exactly", "exact"], ["unique", "uniq"], ["disabled", "disabl"], ["read-only", "read-only|readonly|read only"],
  ["readonly", "read-only|readonly|read only"], ["mandatory", "mandat"], ["default", "default"], ["defaults", "default"],
  ["above", "above"], ["below", "below"],
]
// A comparison symbol may be kept as the symbol or in words.
const SYMBOL_WORDS = {
  "≥": ["≥", ">=", "at least", "minimum", "non-negative", "not negative", "or more", "no less than"],
  ">=": ["≥", ">=", "at least", "minimum", "non-negative", "not negative", "or more", "no less than"],
  "≤": ["≤", "<=", "at most", "maximum", "no more than", "up to", "not exceed"],
  "<=": ["≤", "<=", "at most", "maximum", "no more than", "up to", "not exceed"],
  ">": [">", "positive", "greater than", "more than", "above", "over", "at least 1"],
  "<": ["<", "less than", "below", "under", "fewer than"],
}

// A text as lower-case words: quotes, dashes and punctuation are noise.
function words(text) {
  return String(text || "").toLowerCase().replace(/[“”‘’"'`]/g, "").match(/[\p{L}\p{N}%≥≤]+/gu) || []
}
const flat = (text) => " " + words(text).join(" ") + " "

// The newest request of the project, without its "# Request NN -- date" line, or "".
function latestRequest(root) {
  const dir = join(root || ".", "docs", "brain", "requests")
  try {
    const names = readdirSync(dir).filter((n) => /^\d+\.md$/.test(n)).sort()
    if (!names.length) return ""
    return readFileSync(join(dir, names[names.length - 1]), "utf8").replace(/^# Request.*$/m, "").trim()
  } catch { return "" }
}

// The details a line of the request spells out: [{kind, token, show, ...}]. The same detail once per line.
function lineSpecifics(line) {
  const out = [], seen = new Set()
  const add = (spec) => { const key = spec.kind + ":" + spec.token; if (!seen.has(key)) { seen.add(key); out.push(spec) } }
  for (const m of line.matchAll(/["“]([^"”\n]{3,80})["”]/g)) {
    const head = m[1].split(/\[|…|\.\.\./)[0]
    const w = words(head).slice(0, 3)
    if (w.length >= 2 || (w.length === 1 && w[0].length >= 5)) add({ kind: "quote", token: w.join(" "), show: `"${m[1].trim()}"` })
  }
  for (const m of line.matchAll(/(?<![\w\/.-])[A-Z]{2,4}(?:[\/-][A-Z0-9]{2,4}){1,3}(?![\w])/g)) {
    if (/^(?:AND|OR|NOT)(?:[\/-](?:AND|OR|NOT))+$/.test(m[0])) continue
    add({ kind: "format", token: m[0].toLowerCase(), show: m[0] })
  }
  for (const m of line.matchAll(/(?<![\w.\/-])(\d+(?:[.,]\d+)?)\s*(%|[A-Za-z]{3,})/g)) {
    const next = m[2].toLowerCase()
    add({ kind: "number", number: m[1].replace(",", "."), stem: next === "%" ? "%" : next.slice(0, 4), show: `${m[1]}${next === "%" ? "%" : " " + m[2]}` })
  }
  for (const m of line.matchAll(/\b(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+([A-Za-z]{3,})/gi)) {
    add({ kind: "number", number: String(NUMBER_WORDS[m[1].toLowerCase()]), stem: m[2].toLowerCase().slice(0, 4), show: `${m[1]} ${m[2]}` })
  }
  for (const m of line.matchAll(/(≥|≤|>=|<=|(?<![-=!<>])>(?![>=])|(?<![-<>])<(?![<=]))\s*(\d+)/g)) {
    add({ kind: "bound", token: m[1], show: `${m[1]}${m[2]}` })
  }
  for (const m of line.matchAll(/(?<!\bas\s)\b(exactly|unique|disabled|read-only|readonly|mandatory|defaults?|above|below)\b/gi)) {
    const cue = CUES.find(([w]) => w === m[1].toLowerCase())
    if (cue) add({ kind: "cue", token: cue[1], show: m[1] })
  }
  return out
}

// Whether the text of ONE plan entry repeats the detail.
function keeps(entryText, spec) {
  const text = flat(entryText), raw = String(entryText).toLowerCase()
  if (spec.kind === "quote") return text.includes(" " + spec.token + " ") || text.includes(" " + spec.token)
  if (spec.kind === "format") return raw.includes(spec.token)
  if (spec.kind === "bound") return (SYMBOL_WORDS[spec.token] || [spec.token]).some((w) => raw.includes(w))
  if (spec.kind === "cue") return spec.token.split("|").some((w) => new RegExp("(?:^|[^a-z])" + w).test(raw))
  const n = spec.number, word = WORD_OF[n]
  const hasNumber = new RegExp("(?<![\\d.])" + n.replace(".", "\\.") + "(?![\\d])").test(raw) || (word && new RegExp("\\b" + word + "\\b").test(raw))
  if (!hasNumber) return false
  return spec.stem === "%" ? /%|percent/.test(raw) : new RegExp("(?:^|[^\\p{L}])" + spec.stem, "u").test(raw)
}

// Every entry of the plan and the queue: [{text, open}] -- requirements and assumptions alike.
function planEntries(root) {
  const out = []
  const dir = join(root || ".", "docs", "brain", "plan")
  try {
    for (const name of readdirSync(dir).filter((n) => n.endsWith(".md")).sort()) {
      for (const m of readFileSync(join(dir, name), "utf8").matchAll(/^## (.+)\n\nAnchors: (.*)$/gm)) out.push({ text: m[1].trim(), open: /OPEN\s*$/.test(m[2]) })
    }
  } catch { /* no plan */ }
  try {
    for (const l of readFileSync(join(root || ".", ".mxcli", "brain", "staged.jsonl"), "utf8").split(/\r?\n/).filter(Boolean)) {
      try { const e = JSON.parse(l); if (e && e.title) out.push({ text: String(e.title), open: Boolean(e.open) }) } catch { /* bad line */ }
    }
  } catch { /* no queue */ }
  return out
}

// An assumption that gives up what the request said, and the proof that it had to: the platform's own
// error (a CE code, an error text). "Simpler" is no proof, and neither is one of the harness's own rule
// codes (GRID03, UI001, NAV01): a run recorded "a filter bar above the table is refused (UI001, GRID01,
// GRID03)" and dropped the bar, when the rules allow it in the grid's controlbar (b2b-orders, 2026-10-25).
// A rule names what it refuses, not what the request may not have; an entry that cites one departs.
const DEPARTURE = /\b(?:instead of|rather than|without|not built|not implemented|skip\w*|omit\w*|replac\w*|simplif\w*|defer\w*|stub\w*|hidden|dropped?|no longer)\b/i
const RULE_CODE = /\b[A-Z]{2,12}\d{2,3}\b/
const PROOF = /\bCE\d{4}\b|\b(?:error|refus\w*|fail\w*|unsupported|not supported|impossible)\b/
const departs = (text) => DEPARTURE.test(text) || RULE_CODE.test(text)
const proven = (text) => !RULE_CODE.test(text) && PROOF.test(text)

// The request lines with details the plan does not keep: [{line, missing: [show], departed: [{show, entry}]}].
// `missing`: no entry repeats it. `departed`: only assumptions that give it up, with no proof, repeat it.
function unkept(request, entries) {
  const out = []
  for (const raw of String(request || "").split(/\r?\n/)) {
    const line = raw.replace(/^\s*(?:[*\-•]|\d+[.)])\s+/, "").trim()
    if (line.length < 8) continue
    const missing = [], departed = []
    for (const spec of lineSpecifics(line)) {
      const holders = entries.filter((e) => keeps(e.text, spec))
      if (!holders.length) missing.push(spec.show)
      else if (holders.every((e) => e.open && departs(e.text) && !proven(e.text))) departed.push({ show: spec.show, entry: holders[0].text, rule: (RULE_CODE.exec(holders[0].text) || [""])[0] })
    }
    if (missing.length || departed.length) out.push({ line, missing, departed })
  }
  return out
}

// Whether a captured text repeats a detail of the request (the capture guard lets that through the freeze:
// it restates the request, it adds no feature).
function restatesRequest(root, text) {
  const request = latestRequest(root)
  if (!request) return false
  for (const raw of request.split(/\r?\n/)) {
    for (const spec of lineSpecifics(raw)) if (keeps(text, spec)) return true
  }
  return false
}

module.exports = { latestRequest, lineSpecifics, keeps, planEntries, unkept, restatesRequest, DEPARTURE, PROOF, RULE_CODE }
