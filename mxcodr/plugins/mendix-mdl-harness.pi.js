/**
 * Pi extension mirroring the Claude/Codex/Cursor hooks and the OpenCode plugin; inactive
 * without tests/gate.sh.
 *   tool_call           before `mxcli exec <script>.mdl`: tests/precheck.sh (mx check on a copy of
 *                       the model); errors block the call and the reason is what the model reads
 *   tool_result         after `mxcli exec`: appends after-mxcli-exec.sh output to the tool result
 *                       and remembers that the model changed, so the gate has to run
 *   agent_before_settle Pi's last actionable boundary: runs tests/gate.sh and, unless it says DONE,
 *                       returns the output plus `continue: true` for one more turn
 *                       (at most MAX_GATE_ROUNDS times)
 *
 *   before_agent_start  appends the project rules (.claude/rules/mdl-skills.md) and the syntax
 *                       digest (tools/mdl-checks/syntax-digest.md) to the system prompt
 *
 * The rules come from here, not from a file Pi reads: measured on Pi 0.87.1, `.pi/AGENTS.md` never
 * reached the system prompt -- only the root AGENTS.md did, which mxcli regenerates -- and a session
 * that never saw the rules ran `git init` and a commit unasked, skipped orient.sh and wrote its own
 * page-peeking script.
 *
 * The decisions (the guard, the precheck, the exec footer, the gate message) live in
 * tools/mdl-checks/plugins/harness-core.cjs, shared with the OpenCode plugin.
 *
 * State is per process, which is per session: Pi loads this file once per run, and `session_start`
 * resets it for a branched or switched session.
 */

import { existsSync, readFileSync } from "node:fs"
import { createRequire } from "node:module"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

// The shared core sits beside the checkers: ../checks/plugins in the bundle,
// ../../tools/mdl-checks/plugins once installed (.pi/extensions/ and .opencode/plugin/ are both
// two levels below the project).
function loadCore() {
  // A host may load the file from a data: URL (a probe does): then only the project's copy counts.
  let here = null
  try { here = dirname(fileURLToPath(import.meta.url)) } catch { here = null }
  const require = createRequire(here ? import.meta.url : join(process.cwd(), "noop.js"))
  const candidates = here
    ? [join(here, "..", "checks", "plugins", "harness-core.cjs"), join(here, "..", "..", "tools", "mdl-checks", "plugins", "harness-core.cjs")]
    : []
  candidates.push(join(process.cwd(), "tools", "mdl-checks", "plugins", "harness-core.cjs"))
  for (const candidate of candidates) {
    if (existsSync(candidate)) return require(candidate)
  }
  throw new Error("mendix-mdl-harness: tools/mdl-checks/plugins/harness-core.cjs is missing -- re-run the installer (bash mxcodr/install.sh .)")
}
const core = loadCore()

// Marks the rules once they are in the system prompt, so a second handler run adds nothing.
const RULES_MARKER = "<mendix-project-rules>"

export default function mendixMdlHarness(pi) {
  // Per-session, and reset when Pi starts, branches or switches a session.
  let gateRequired = false
  let rounds = 0
  let running = false

  const harnessRoot = (ctx) => {
    const root = ctx && ctx.cwd ? ctx.cwd : process.cwd()
    return existsSync(join(root, "tests", "gate.sh")) ? root : null
  }

  // Pi rebuilds the system prompt for every agent run, so the rules are appended each time; the
  // file is read once per process. The marker keeps a second handler from adding them twice.
  let rulesText = null
  let digestText = ""
  const readOr = (path, fallback) => {
    try {
      return existsSync(path) ? readFileSync(path, "utf8") : fallback
    } catch {
      return fallback
    }
  }
  pi.on("before_agent_start", (event, ctx) => {
    const root = harnessRoot(ctx)
    if (!root) return
    if (rulesText === null) rulesText = readOr(join(root, ".claude", "rules", "mdl-skills.md"), "")
    // The syntax digest appears once orient.sh or the installer has written it; until then it is
    // looked for again on every run. A file to read was not enough: a session listed its table
    // of contents and still asked `./mxcli syntax` 165 times.
    if (!digestText) digestText = readOr(join(root, "tools", "mdl-checks", "syntax-digest.md"), "")
    if (!rulesText || (event.systemPrompt || "").includes(RULES_MARKER)) return
    return {
      systemPrompt:
        `${event.systemPrompt || ""}\n\n${RULES_MARKER}\n` +
        "The rules below are this Mendix project's own and apply to the whole session.\n\n" +
        `${rulesText}\n` +
        (digestText ? `\n${digestText}\n` : "") +
        "</mendix-project-rules>",
    }
  })

  pi.on("session_start", () => {
    gateRequired = false
    rounds = 0
    running = false
  })

  // The guard, the sleep block and tests/precheck.sh (mx check on a scratch copy of the model):
  // a reason blocks the call, and is what the model reads instead of the tool output.
  pi.on("tool_call", (event, ctx) => {
    const root = harnessRoot(ctx)
    if (!root) return
    const reason = core.blockReason(root, event.toolName, event.input)
    if (reason) return { block: true, reason }
  })

  pi.on("tool_result", (event, ctx) => {
    if (event.toolName !== "bash") return
    const root = harnessRoot(ctx)
    if (!root) return
    const command = event.input && event.input.command
    if (!core.isMxcliExec(command)) return

    gateRequired = true

    const text = (event.content || []).filter((part) => part && part.type === "text").map((part) => part.text).join("\n")
    const out = core.afterExecText(root, command, text)
    if (!out) return
    return { content: [...event.content, { type: "text", text: out }] }
  })

  // Pi's last actionable boundary. `continue: true` buys exactly one more model request, so a red
  // gate comes back as work rather than as a finished turn.
  pi.on("agent_before_settle", async (event, ctx) => {
    if (!gateRequired || running) return
    if (event.outcome !== "completed") return
    const root = harnessRoot(ctx)
    if (!root) return
    if (rounds >= core.MAX_GATE_ROUNDS) {
      gateRequired = false
      return
    }

    running = true
    try {
      const gate = core.run("bash tests/gate.sh", root, core.GATE_TIMEOUT_MS)
      if (gate.status === 0 && gate.out.includes(core.GATE_DONE)) {
        gateRequired = false
        rounds = 0
        return
      }
      rounds += 1
      return {
        entries: [
          {
            type: "custom_message",
            customType: "mendix-mdl-gate",
            content: core.gateFailureMessage(gate.out),
            display: true,
          },
        ],
        continue: true,
      }
    } finally {
      running = false
    }
  })
}
