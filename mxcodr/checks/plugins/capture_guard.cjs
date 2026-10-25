/**
 * checks/plugins/capture_guard.cjs -- keeps the build inside the approved requirements, at the one
 * place a requirement enters the plan: `./mxcli brain capture`. Self-contained (no parent requires),
 * like request_archive.cjs, because the plugins load it from the bundle or from an installed project.
 *
 * Two refusals, both only at `requirements: assume` (nobody answers, the agent promotes its own
 * requirements; with a person in the chat their yes is the freeze):
 *
 *   FROZEN   the plan already holds a promoted requirement and the app has not reached its first
 *            DONE: the approved requirements ARE the scope, so a new requirement is refused. A later
 *            request (after DONE) is REQ03's business and stays open. `--open` captures (assumptions)
 *            and captures with no --slice (decisions) add no feature and pass.
 *            A requirement that repeats a detail of the request (request_specifics.cjs: a number, a quoted
 *            caption, a format, a bound, "disabled") passes: it keeps what was asked (REQ04), it adds nothing.
 *   BEYOND   a requirement that asks for an analytics-type feature (dashboard, KPI, statistics, totals,
 *            summary, tiles, charts, reports) in words the request never used. Two runs of one
 *            two-sentence prompt differed 6 to 9 flows because one added a dashboard and a log of its own
 *            (invoice-chase iq3a/iq3b, 2026-10-24); the plan of the second one is "approved" but was never
 *            asked for. Soft: the first capture with such words is refused once and the words are noted in
 *            .mxcli/capture-warned.txt; the same words again go through (the agent has read the warning and
 *            keeps the requirement on purpose). The person found a hard refusal here too intrusive
 *            (2026-10-24); the freeze above stays hard.
 */

const { existsSync, readFileSync, readdirSync, mkdirSync, appendFileSync } = require("node:fs")
const { join } = require("node:path")

// MDL_REQUIREMENTS from tests/harness.env (the last line wins), else the environment, else ask.
function requirementsMode(root) {
  let mode = process.env.MDL_REQUIREMENTS || "ask"
  try {
    const text = readFileSync(join(root || ".", "tests", "harness.env"), "utf8")
    for (const m of text.matchAll(/^\s*MDL_REQUIREMENTS=["']?(\w+)["']?\s*$/gm)) mode = m[1]
  } catch { /* no harness.env */ }
  return mode
}

// The simple commands of a shell line as word lists, quotes honoured: a requirement is a sentence with
// `;` in it ("...; checked when ..."), which a plain split on `;` cuts in two.
function simpleCommands(line) {
  const commands = []
  let words = [], word = "", quote = "", has = false
  const endWord = () => { if (has) words.push(word); word = ""; has = false }
  const endCommand = () => { endWord(); if (words.length) commands.push(words); words = [] }
  const text = String(line || "")
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (quote) {
      if (c === quote) quote = ""
      else if (c === "\\" && quote === '"' && i + 1 < text.length && /["\\$`]/.test(text[i + 1])) word += text[++i]
      else word += c
      continue
    }
    if (c === '"' || c === "'") { quote = c; has = true; continue }
    if (c === "\\" && i + 1 < text.length) { word += text[++i]; has = true; continue }
    if (c === " " || c === "\t") { endWord(); continue }
    if (c === "\n" || c === ";" || c === "|" || c === "&") { endCommand(); continue }
    word += c; has = true
  }
  endCommand()
  return commands
}

// `./mxcli [-p x.mpr] brain capture <text> [--open] [--slice s] [-a @x]...` -> {text, open, slice} or null.
function parseCapture(words) {
  const at = words.findIndex((w) => /(^|[\/\\])mxcli(\.exe)?$/.test(w))
  if (at < 0) return null
  const rest = words.slice(at + 1)
  const i = rest.findIndex((w, k) => w === "brain" && rest[k + 1] === "capture")
  if (i < 0) return null
  const args = rest.slice(i + 2)
  let text = "", open = false, slice = ""
  for (let k = 0; k < args.length; k++) {
    const a = args[k]
    if (a === "--open") open = true
    else if (a === "--slice" || a === "-s") slice = args[++k] || ""
    else if (a.startsWith("--slice=")) slice = a.slice(8)
    else if (a === "-a" || a === "--anchor" || a === "-p" || a === "--project") k++
    else if (a.startsWith("-")) continue
    else if (!text) text = a
  }
  return { text, open, slice }
}

// Whether the plan holds a requirement the agent has promoted (an entry of docs/brain/plan/<slice>.md
// that is not an open question) and the app has not yet reached its first full DONE.
function frozen(root) {
  const dir = join(root || ".", "docs", "brain", "plan")
  let promoted = false
  try {
    for (const name of readdirSync(dir).filter((n) => n.endsWith(".md"))) {
      const text = readFileSync(join(dir, name), "utf8")
      for (const m of text.matchAll(/^## .+\n\nAnchors: (.*)$/gm)) if (!/OPEN\s*$/.test(m[1])) promoted = true
    }
  } catch { return false }
  if (!promoted) return false
  try { if (/^full: \S+ \S+ DONE\b/m.test(readFileSync(join(root || ".", ".mxcli", "last-gate.txt"), "utf8"))) return false } catch { /* no gate yet */ }
  return true
}

// What the person asked for, in their own words: docs/brain/requests/NN.md without the heading line.
function requestText(root) {
  const dir = join(root || ".", "docs", "brain", "requests")
  let text = ""
  try {
    for (const name of readdirSync(dir).filter((n) => n.endsWith(".md"))) {
      text += "\n" + readFileSync(join(dir, name), "utf8").replace(/^# Request.*$/gm, "")
    }
  } catch { /* no archive: nothing to compare with */ }
  return text.toLowerCase()
}

// Analytics-type features. A request that says "dashboard" or "totals" itself may ask for them; one that
// does not is not asking, whatever the plan says. Deliberately short and plain: singular "total" is
// left out (an invoice has one), and so are log, note, history and edit (journeys the words of a request
// often imply).
const BEYOND_WORDS = /\b(dashboards?|kpis?|statistics?|stats|analytics?|totals|summar(?:y|ies)|tiles?|charts?|graphs?|metrics|reports?|reporting)\b/gi
function beyondRequest(root, text) {
  const request = requestText(root)
  if (!request.trim()) return []
  const found = new Set()
  for (const m of String(text).matchAll(BEYOND_WORDS)) {
    const word = m[1].toLowerCase()
    const stem = word.replace(/(ies|y|s|ing)$/, "").slice(0, 5)
    if (!request.includes(stem)) found.add(word)
  }
  return [...found]
}

// Words already warned about in this app: .mxcli/capture-warned.txt, one per line.
function warned(root, word) {
  try { return readFileSync(join(root || ".", ".mxcli", "capture-warned.txt"), "utf8").split("\n").includes(word) } catch { return false }
}
function noteWarned(root, words) {
  try {
    mkdirSync(join(root || ".", ".mxcli"), { recursive: true })
    appendFileSync(join(root || ".", ".mxcli", "capture-warned.txt"), words.join("\n") + "\n")
  } catch { /* cannot note: the warning repeats, harmless */ }
}

const FROZEN_CAPTURE =
  "Blocked: the scope is frozen. The requirements you promoted are what this app is built from (MDL_REQUIREMENTS=assume " +
  "in tests/harness.env: nobody answers, so your own promotion is the approval), and a new one now only widens the build. " +
  "Do not add it. Put the idea under \"to add next\" in your final report: the person approves it there, or a later request " +
  "records it (the gate lists it then). What is still open stays allowed: an assumption (`--open`, \"Assumed: ...\") adds no feature. " +
  "Next time capture every requirement first and promote them together."

function beyondMessage(words) {
  return (
    `Blocked: this requirement asks for ${words.map((w) => `"${w}"`).join(", ")}, which the request never mentions (docs/brain/requests/). ` +
    "A dashboard, totals, summary, tiles, chart or report is a feature of its own; the request has to ask for it. " +
    "Leave it out of the requirements, build the journeys the request's words name, and list the idea under \"to add next\" " +
    "in your final report. If the request does ask for it in other words, or you keep it on purpose, capture it again: it goes through the second time."
  )
}

// The block message for a command that runs `mxcli brain capture` against the scope, or null.
function captureBlock(root, command) {
  if (typeof command !== "string" || !command.includes("capture")) return null
  if (requirementsMode(root) !== "assume") return null
  const captures = simpleCommands(command).map(parseCapture).filter(Boolean)
  const requirements = captures.filter((c) => c.slice && !c.open)
  if (!requirements.length) return null
  for (const c of requirements) {
    const words = beyondRequest(root, c.text)
    const fresh = words.filter((w) => !warned(root, w))
    if (fresh.length) { noteWarned(root, fresh); return beyondMessage(fresh) }
  }
  // A requirement that repeats a detail of the request (a number, a quoted caption, a format, "disabled") adds
  // no feature: it keeps what was asked, REQ04's fix. Only a new idea is refused.
  if (frozen(root)) {
    let spec = null
    try { spec = require("./request_specifics.cjs") } catch { /* the guard works without it */ }
    if (spec && requirements.every((c) => spec.restatesRequest(root, c.text))) return null
    return FROZEN_CAPTURE
  }
  return null
}

module.exports = { captureBlock, parseCapture, simpleCommands, frozen, requestText, beyondRequest, FROZEN_CAPTURE, beyondMessage }
