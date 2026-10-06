/**
 * OpenCode plugin mirroring the Claude/Codex/Cursor hooks; inactive without tests/gate.sh.
 *   chat.message        appends the reminder (tools/mdl-checks/reminder.txt) to each user message
 *   tool.execute.before before `mxcli exec <script>.mdl`: tests/precheck.sh (mx check on a copy); errors abort the call
 *   tool.execute.after  after `mxcli exec`: marks the session, appends after-mxcli-exec.sh output to the tool result
 *   event session.idle  runs tests/gate.sh; unless DONE, sends the output back as a message (max MAX_GATE_ROUNDS)
 * State: <tmpdir>/mendix-mdl-opencode-hooks/<session>.gate-required | .running | .rounds
 *
 * The decisions (the guard, the precheck, the exec footer, the gate message) live in
 * tools/mdl-checks/plugins/harness-core.cjs, shared with the Pi extension.
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

// The shared core sits beside the checkers: ../checks/plugins in the bundle,
// ../../tools/mdl-checks/plugins once installed (.opencode/plugin/ and .pi/extensions/ are both
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

// Per-session state on disk, so it survives reloads.
const STATE = join(tmpdir(), "mendix-mdl-opencode-hooks")

function statePath(sessionID, suffix) {
  const safe = String(sessionID).replace(/[^A-Za-z0-9._-]/g, "")
  return safe ? join(STATE, `${safe}.${suffix}`) : null
}

function readState(sessionID, suffix) {
  const path = statePath(sessionID, suffix)
  if (!path || !existsSync(path)) return null
  try {
    return readFileSync(path, "utf8").trim()
  } catch {
    return null
  }
}

function writeState(sessionID, suffix, value) {
  const path = statePath(sessionID, suffix)
  if (!path) return
  try {
    mkdirSync(STATE, { recursive: true })
    writeFileSync(path, String(value))
  } catch {
    /* state is an optimisation, never a reason to fail a turn */
  }
}

function clearState(sessionID, suffix) {
  const path = statePath(sessionID, suffix)
  if (path) try { rmSync(path, { force: true }) } catch { /* ignore */ }
}

export const MendixMdlHarness = async ({ client, directory, worktree }) => {
  const root = worktree || directory

  const installed = existsSync(join(root, "tests", "gate.sh"))
  const RULES = core.reminder(root, {
    rulesFile: ".claude/rules/mdl-skills.md",
    loadSkill: "read `.ai-context/skills/test-first-delivery/SKILL.md`",
    precheck: "(a hook runs `tests/precheck.sh` for you -- mx check on a copy; do not call it by hand)",
  })

  return {
    // Append to the user's text part; a new TextPart would need ids and could break the turn.
    "chat.message": async (_input, output) => {
      if (!installed) return
      const text = (output.parts || []).find((part) => part.type === "text" && typeof part.text === "string")
      if (!text || text.text.includes("bash tests/orient.sh")) return
      text.text = `${text.text}\n\n${RULES}`
    },

    // The guard, the sleep block and tests/precheck.sh (mx check on a scratch copy of the model):
    // a reason aborts the call, and the thrown message is what the model reads instead of the
    // tool output.
    "tool.execute.before": async (input, output) => {
      if (!installed) return
      const reason = core.blockReason(root, input.tool, output.args)
      if (reason) throw new Error(reason)
    },

    "tool.execute.after": async (input, output) => {
      if (!installed) return
      if (input.tool !== "bash") return
      const command = input.args?.command
      if (!core.isMxcliExec(command)) return

      writeState(input.sessionID, "gate-required", root)

      const out = core.afterExecText(root, command, output.output || "")
      if (!out) return
      output.output = `${output.output || ""}\n\n${out}`
    },

    // session.idle is OpenCode's closest "finishing" signal; a red gate is sent back as the next message.
    event: async ({ event }) => {
      if (!installed) return
      if (event?.type !== "session.idle") return
      const sessionID = event.properties?.sessionID || event.properties?.info?.id
      if (!sessionID) return
      if (!readState(sessionID, "gate-required")) return
      // session.idle fires again while the gate runs.
      if (readState(sessionID, "running")) return
      // Waiting for the person's Marketplace login: stay idle so they can answer.
      if (core.marketplacePending(root)) return
    // Films recording in the background hold the browser: the gate would refuse; check next turn.
    if (core.filmsRecording(root)) return

      const rounds = Number(readState(sessionID, "rounds") || 0)
      if (rounds >= core.MAX_GATE_ROUNDS) {
        clearState(sessionID, "gate-required")
        return
      }

      writeState(sessionID, "running", "1")
      try {
        const gate = core.run("bash tests/gate.sh", root, core.GATE_TIMEOUT_MS)
        if (gate.status === 0 && gate.out.includes(core.GATE_DONE)) {
          clearState(sessionID, "gate-required")
          clearState(sessionID, "rounds")
          return
        }
        writeState(sessionID, "rounds", rounds + 1)
        await client.session.prompt({
          path: { id: sessionID },
          body: { parts: [{ type: "text", text: core.gateFailureMessage(gate.out) }] },
        })
      } catch (error) {
        await client.app?.log?.({
          body: { service: "mendix-mdl-harness", level: "error", message: String(error) },
        })
      } finally {
        clearState(sessionID, "running")
      }
    },
  }
}
