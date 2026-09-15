/**
 * OpenCode plugin: the same three jobs the Claude, Codex and Cursor hooks do.
 *
 *   1. state the rules on every user message   -> chat.message
 *   2. check coverage after `mxcli exec`       -> tool.execute.after
 *   3. gate the finish                         -> event(session.idle) + session.prompt
 *
 * OpenCode has no exit-code contract like Codex, and no followup_message field like
 * Cursor. Its equivalents are mutable hook payloads (the text the model sees can be
 * appended to in place) and the SDK client, which can submit a new message into the
 * session. Both are used below and nothing else is invented.
 *
 * Plain JavaScript, no dependencies and no build step: opencode loads
 * .opencode/plugin/*.js directly.
 */

import { spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"

// The hooks and the gate are bash scripts on every host. On Windows that means Git
// Bash, which a GUI-launched process often does not have on its PATH -- so the
// install directory is tried too, and each candidate is run once before it is
// believed rather than merely tested for existence.
function resolveBash() {
  if (process.platform !== "win32") return "bash"
  // Git's own directories first, and PATH last: on Windows 11 the first bash.exe
  // on the PATH is C:\Windows\System32\bash.exe, which is the WSL launcher --
  // a different filesystem, no mxcli.exe, and a baffling failure later.
  const candidates = [
    `${process.env.ProgramFiles || "C:\\Program Files"}\\Git\\bin\\bash.exe`,
    `${process.env["ProgramFiles(x86)"] || ""}\\Git\\bin\\bash.exe`,
    `${process.env.LOCALAPPDATA || ""}\\Programs\\Git\\bin\\bash.exe`,
    "bash.exe",
  ]
  for (const candidate of candidates) {
    if (candidate !== "bash.exe" && !existsSync(candidate)) continue
    const probe = spawnSync(candidate, ["-c", "exit 0"], { timeout: 15000 })
    if (!probe.error && probe.status === 0) return candidate
  }
  return null
}

const BASH = resolveBash()
const NO_BASH =
  "The Mendix harness runs its checks as bash scripts, and no bash was found. " +
  "Install Git for Windows and make sure bash.exe is on the PATH."

const RULES = [
  "Project rule: start by running `bash tests/orient.sh` (one call, ~0.3s: structure, security,",
  "navigation, tests and their covers, coverage, lint, app state) instead of exploring by hand.",
  "Before building or changing any feature read `.ai-context/skills/test-first-delivery/SKILL.md`",
  "(failing test first). Before creating a module or placing documents: `module-structure`.",
  "Before writing a microflow: `naming-and-captions` — every decision AND every action",
  "(retrieve, create, change, commit, delete, call, show page, set) needs a business `@caption`,",
  "never the Mendix default; the gate's naming check fails on either.",
  "Run the new test and watch it FAIL before",
  "implementing: `bash tests/gate.sh --only <feature> --boot-if-needed`. While you iterate run",
  "that same ONE script; when it goes red the gate prints the facts under the failure by itself.",
  "A feature is not done until `bash tests/gate.sh` (suite + mx check + lint + coverage) ends in",
  "`DONE`.",
].join(" ")

// The gate is slow and session.idle can fire repeatedly. State lives on disk so a
// reload does not lose it, keyed by session.
const STATE = join(tmpdir(), "mendix-mdl-opencode-hooks")
const MAX_GATE_ROUNDS = 3

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

function run(command, cwd, timeout, input) {
  if (!BASH) return { status: 1, out: NO_BASH }
  // -c, not -lc: a login shell on Git Bash re-reads the profile on every call, which
  // can move the cwd and reorder PATH, and costs real time on a hook that fires
  // after every tool call. `input` goes to the script's stdin untouched, so data
  // never has to survive being quoted into a shell command line.
  const result = spawnSync(BASH, ["-c", command], {
    cwd,
    input,
    timeout: timeout ?? 120000,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  })
  return {
    status: result.status ?? 1,
    out: `${result.stdout ?? ""}${result.stderr ?? ""}`.trim(),
  }
}

export const MendixMdlHarness = async ({ client, directory, worktree }) => {
  const root = worktree || directory

  // No harness here means no opinions here: an app without tests/gate.sh is not a
  // project this plugin has anything to say about.
  const installed = existsSync(join(root, "tests", "gate.sh"))

  return {
    /**
     * The rules, on every message rather than once per session. Appended to the
     * user's own text part instead of pushing a new part: a TextPart requires id,
     * sessionID and messageID, and a malformed part would break the turn.
     */
    "chat.message": async (_input, output) => {
      if (!installed) return
      const text = (output.parts || []).find((part) => part.type === "text" && typeof part.text === "string")
      if (!text || text.text.includes("bash tests/orient.sh")) return
      text.text = `${text.text}\n\n${RULES}`
    },

    /**
     * Coverage after a model write. `output.output` is the tool result the model
     * reads, so appending to it is how feedback reaches the conversation.
     */
    "tool.execute.after": async (input, output) => {
      if (!installed) return
      if (input.tool !== "bash") return
      const command = input.args?.command
      // mxcli.exe on Windows: "mxcli.exe exec" does not contain "mxcli exec".
      if (typeof command !== "string" || !/mxcli(\.exe)? exec/.test(command)) return

      writeState(input.sessionID, "gate-required", root)

      const hook = join(root, "tools", "mdl-checks", "hooks", "after-mxcli-exec.sh")
      if (!existsSync(hook)) return
      // Forward slashes: join() gives backslashes on Windows, and this path is going
      // into a bash command line, where a backslash is an escape.
      const hookPath = hook.replace(/\\/g, "/")
      // The shared script reads a Claude-shaped payload. It gets the real command --
      // until 2026.09.13 it got the literal words "mxcli exec", so it could never see
      // which script ran and told every OpenCode session that no restart was needed,
      // including after entity changes.
      const payload = JSON.stringify({ tool_input: { command } })
      const { out } = run(`bash ${JSON.stringify(hookPath)}`, root, undefined, payload)
      if (!out) return
      output.output = `${output.output || ""}\n\n${out}`
    },

    /**
     * The gate. session.idle is the closest thing OpenCode has to "the session is
     * finishing"; on a red gate the plugin submits its output as the next message,
     * which is the same effect as Codex's exit 2 and Cursor's followup_message.
     */
    event: async ({ event }) => {
      if (!installed) return
      if (event?.type !== "session.idle") return
      const sessionID = event.properties?.sessionID || event.properties?.info?.id
      if (!sessionID) return
      if (!readState(sessionID, "gate-required")) return
      // session.idle fires again while the gate runs; without this the gate stacks.
      if (readState(sessionID, "running")) return

      const rounds = Number(readState(sessionID, "rounds") || 0)
      if (rounds >= MAX_GATE_ROUNDS) {
        clearState(sessionID, "gate-required")
        return
      }

      writeState(sessionID, "running", "1")
      try {
        const { status, out } = run("bash tests/gate.sh", root, 900000)
        if (status === 0 && out.includes("DONE — every check passed")) {
          clearState(sessionID, "gate-required")
          clearState(sessionID, "rounds")
          return
        }
        writeState(sessionID, "rounds", rounds + 1)
        await client.session.prompt({
          path: { id: sessionID },
          body: {
            parts: [
              {
                type: "text",
                text:
                  "The project gate has not passed, so this feature is not done. " +
                  "Fix the failures below and run `bash tests/gate.sh` again:\n\n" +
                  out.slice(-6000),
              },
            ],
          },
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
