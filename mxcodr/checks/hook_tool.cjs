// The small jobs the hooks give to a script: read a field of the tool call, split a command like
// a shell, wrap a message in the JSON a host wants. One file with one subcommand per job, each the
// Node port of a Python snippet that used to sit inline in a hook.
//
//     <stdin> | node hook_tool.cjs <subcommand> [args]
//
// Exit 0; a subcommand that cannot read its input prints nothing, as the snippet did.
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const py = require('./py_compat.cjs');
const { re } = py;

const isDict = v => v !== null && typeof v === 'object' && !Array.isArray(v);
// json.load(sys.stdin): the parsed call, or undefined when it is not JSON.
function load() {
  try {
    return JSON.parse(py.readStdin());
  } catch {
    return undefined;
  }
}
// d.get(key, default) on a value that must be a dict; undefined plays AttributeError.
function get(d, key, dflt) {
  if (!isDict(d)) return undefined;
  return key in d ? d[key] : dflt;
}
// Python's `or`: the first truthy value.
const truthy = v => !(v === undefined || v === null || v === false || v === 0 || v === '' ||
  (Array.isArray(v) && !v.length) || (isDict(v) && !Object.keys(v).length));
const or = (...values) => values.find(truthy) ?? values[values.length - 1];

// The words of a command, split like a shell; on an unclosed quote, split on whitespace.
function shellWords(text) {
  try {
    return py.shlexSplit(text);
  } catch {
    return py.split(text);
  }
}

// A word with a glob in it, expanded and sorted -- [] when it matches more than 200 paths: a
// hook runs after every terminal command, and /*/*/*/*/* took 14 seconds on this machine.
function expand(word) {
  const matches = [];
  if (/[*?[]/.test(word) && (word.match(/\*/g) || []).length <= 4) {
    for (const match of py.sorted(py.glob(word))) {
      if (matches.length >= 200) return [];
      matches.push(match);
    }
  }
  return matches;
}

const EXEC = String.raw`(?:^|[\s;&|(])(?:\./)?mxcli(?:\.exe)?\s+exec\b`;

const tools = {
  // print(d.get("tool_input", {}).get("command", ""))
  command() {
    const input = get(load(), 'tool_input', {});
    const command = get(input, 'command', '');
    if (command !== undefined) py.print(command);
  },
  // Cursor: print(d.get("command") or d.get("tool_input", {}).get("command", ""))
  'cursor-command'() {
    const d = load();
    if (!isDict(d)) return;
    const own = d.command;
    if (truthy(own)) { py.print(own); return; }
    const command = get(get(d, 'tool_input', {}), 'command', '');
    if (command !== undefined) py.print(command);
  },
  // try: print(json.load(sys.stdin).get(key) or "") except Exception: print("")
  get(key) {
    const d = load();
    py.print(isDict(d) ? or(d[key], '') : '');
  },
  // print(json.load(sys.stdin).get(key, "")) -- None prints as None.
  'get-default'(key) {
    const d = load();
    if (!isDict(d)) return;
    py.print(key in d ? d[key] : '');
  },
  // Cursor's stop payload: the workspace roots, one per line.
  roots() {
    const d = load();
    let roots = [];
    if (isDict(d)) roots = or(d.workspace_roots, []);
    if (!Array.isArray(roots)) roots = typeof roots === 'string' ? [...roots] : isDict(roots) ? Object.keys(roots) : [];
    py.print(roots.filter(r => typeof r === 'string').join('\n'));
  },
  // json.dumps({key: sys.stdin.read().strip()})
  wrap(key) {
    py.print(py.jsonDumps({ [key]: py.strip(py.readStdin()) }));
  },
  // The Claude PreToolUse context: the first line of the precheck's output, if any.
  'pre-context'() {
    const line = py.strip(py.readStdin());
    if (line) py.print(py.jsonDumps({ hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: line } }));
  },
  // The Claude PostToolUse context: what the model reads after the tool's own result.
  'post-context'() {
    const text = py.strip(py.readStdin());
    if (text) py.print(py.jsonDumps({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: text } }));
  },
  // Cursor's deny: the agent reads the whole message, the person a line saying what was blocked.
  // Every deny used to tell the person "the script would break the build" -- also for a grep of the
  // mxcli binary or a read of the gate's code, which have nothing to do with a build (2026-10-13).
  deny() {
    const message = py.readStdin();
    const head = /^Blocked: (that [^(.]*?)(?: \(|\.)/.exec(message);
    const userMessage = /precheck/i.test(message.split('\n')[0])
      ? 'mxcli exec blocked: the script would break the build (see the agent message).'
      : head ? `Command blocked: ${head[1].trim()} (see the agent message).` : 'Command blocked (see the agent message).';
    py.print(py.jsonDumps({ permission: 'deny', userMessage, agentMessage: message }));
  },
  // Cursor's deny for the guard.
  'guard-deny'() {
    py.print(py.jsonDumps({ permission: 'deny', userMessage: 'Blocked a change to the gate switches in tests/harness.env.', agentMessage: py.readStdin() }));
  },
  // A Claude-shaped Bash call around a command, for the guard.
  'bash-payload'() {
    py.print(py.jsonDumps({ tool_name: 'Bash', tool_input: { command: py.readStdin() } }));
  },
  // Cursor's postToolUse payload, reduced to the exec command after-mxcli-exec.sh reads.
  'cursor-payload'() {
    const found = [];
    const strings = v => {
      if (typeof v === 'string') found.push(v);
      else if (Array.isArray(v)) v.forEach(strings);
      else if (isDict(v)) Object.values(v).forEach(strings);
    };
    strings(load() ?? null);
    const command = found.find(s => s.includes('mxcli exec') || s.includes('mxcli.exe exec')) ?? 'mxcli exec';
    py.print(py.jsonDumps({ tool_input: { command: command.split('\\').join('/') } }));
  },
  // One line saying whether an exec applied, read from its output.
  'exec-verdict'() {
    const d = load();
    if (!isDict(d)) return;
    const r = d.tool_response;
    const text = isDict(r) ? ['stdout', 'stderr', 'output'].map(k => py.pyStr(or(r[k], ''))).join('\n') : py.pyStr(or(r, ''));
    // The command is read before the output is judged: a tool_input that is not an object stops
    // the whole verdict, as d.get("tool_input", {}).get(...) raised.
    const input = get(d, 'tool_input', {});
    if (!isDict(input)) return;
    const applied = re.search(String.raw`^\s*(Created|Modified|Replaced|Updated|Dropped|Altered|Moved|Granted|Revoked)\b|already in sync`, text, 'm');
    if (re.search(String.raw`Nothing was written|Refusing to execute|^\s*Parse error\b`, text, 'm')) {
      py.print('exec: FAILED -- mxcli wrote nothing; the reason is in its output above. Fix the script and exec it again.');
    } else if (applied && re.search(String.raw`^\s*(Error|error)\b`, text, 'm')) {
      // `mxcli exec x.mdl && bash tests/gate.sh --restart`: the exec applied, the boot after it failed.
      // "FAILED -- wrote nothing" sent a session to fix a script that had applied (2026-10-12).
      py.print('exec: applied. An Error line in this output comes from a later step of the same command (a boot or the gate), not from the exec: the model has the change.');
    } else if (re.search(String.raw`^\s*(Error|error)\b`, text, 'm')) {
      py.print('exec: FAILED -- mxcli wrote nothing; the reason is in its output above. Fix the script and exec it again.');
    } else if (applied) {
      py.print('exec: applied. ("0 errors, N warnings" in mxcli output is a count, not a failure.)');
    } else {
      const command = get(input, 'command', '');
      if (typeof command !== 'string') return;
      if (re.search(String.raw`\bgrep\b.*error`, command, 'i')) {
        py.print('exec: its output went through grep, so this cannot tell whether it applied. mxcli prints ' +
          '"Nothing was written" and exits 1 when it refuses a script; "0 errors, N warnings" is a count, not a failure.');
      }
    }
  },
  // The words of a command with globs expanded, one per line (after-mxcli-exec.sh).
  words() {
    for (const word of shellWords(py.readStdin())) {
      const matches = expand(word);
      py.print(matches.length ? matches.join('\n') : word);
    }
  },
  // The .mdl words of a command, one per line, $PWD resolved, globs expanded. A microflow test
  // (`*.test.mdl`) is never an exec script: `mxcli exec a.mdl; mxcli check tests/x.test.mdl` had the
  // test file prechecked as a script and refused (room-booking-t1, 2026-10-16).
  scripts() {
    const seen = new Set();
    for (let word of shellWords(py.readStdin())) {
      if (!word.endsWith('.mdl') || word.endsWith('.test.mdl') || seen.has(word)) continue;
      // `$PWD/mdlsource/x.mdl` is the project itself, not a loop variable.
      for (const v of ['${PWD}/', '$PWD/', '$(pwd)/']) {
        if (word.startsWith(v)) word = process.cwd() + '/' + word.slice(v.length);
      }
      seen.add(word);
      const all = expand(word);
      const matches = all.filter((m) => !m.endsWith('.test.mdl'));
      if (all.length && !matches.length) continue;
      py.print(matches.length ? matches.join('\n') : word);
    }
  },
  // The scripts the command execs: the first .mdl word after each `mxcli exec`, expanded, one per
  // line. `scripts` lists every .mdl word, a heredoc's target and a `check`'s argument included:
  // STALE01 recorded those as applied, then refused their first exec as "would undo later changes"
  // to documents that did not exist yet (leave-l2, 2026-10-18).
  'exec-scripts'() {
    let mxcli = false, exec = false;
    for (let word of shellWords(py.readStdin())) {
      const ends = /[;&|]+$/.test(word) && word.length > 1;  // `a.mdl;` is one word to shlex
      if (ends) word = word.replace(/[;&|]+$/, '');
      if (/(^|\/)mxcli(\.exe)?$/.test(word)) { mxcli = true; exec = false; continue; }
      if (['|', ';', '&&', '||', '>', '>>', '<<', '&'].includes(word)) { mxcli = exec = false; continue; }
      if (mxcli && !exec && word === 'exec') { exec = true; continue; }
      if (!exec || !word.endsWith('.mdl') || word.endsWith('.test.mdl')) { if (ends) mxcli = exec = false; continue; }
      for (const v of ['${PWD}/', '$PWD/', '$(pwd)/']) {
        if (word.startsWith(v)) word = process.cwd() + '/' + word.slice(v.length);
      }
      const matches = expand(word).filter((m) => !m.endsWith('.test.mdl'));
      py.print(matches.length ? matches.join('\n') : word);
      mxcli = exec = false;
    }
  },
  // MDL given to mxcli with -c that changes the model, NUL-separated.
  'inline-mdl'() {
    let words;
    try {
      words = py.shlexSplit(py.readStdin());
    } catch {
      return;
    }
    let seenMxcli = false;
    words.forEach((word, i) => {
      if (re.search(String.raw`(^|/)mxcli(\.exe)?$`, word)) seenMxcli = true;
      else if (['|', ';', '&&', '||'].includes(word)) seenMxcli = false;
      else if (seenMxcli && word === '-c' && i + 1 < words.length) {
        if (re.match(String.raw`\s*(create|alter|drop|grant|revoke|move|rename)\b`, words[i + 1], 'i')) py.write(words[i + 1] + '\0');
      }
    });
  },
  // A note when the command does more than set variables or cd before its `mxcli exec`.
  'steps-before-exec'() {
    const text = py.readStdin();
    const m = re.search(EXEC, text);
    if (!m) return;
    const trivial = re.compile(String.raw`^((export\s+)?[A-Za-z_]\w*=("[^"]*"|'[^']*'|\S*)\s*)*$|^cd\s+\S+$`);
    for (const step of re.split(String.raw`&&|\|\||[;|\n]`, text.slice(0, m.start()))) {
      if (!trivial.match(py.strip(step)) && !require('./plugins/harness-core.cjs').readOnlyStep(py.strip(step))) {
        py.print('Nothing in this command ran, the steps before the exec included (an edit there never happened): the script was checked as it is on disk. Run those steps on their own, then the exec as its own command.');
        break;
      }
    }
  },
  // The person-only codes behind a red gate (output on stdin), as the agent is told them; nothing
  // when the agent still has work (harness-core personOnly).
  'person-only'(root) {
    const core = require('./plugins/harness-core.cjs');
    const codes = core.personOnly(root || '.', py.readStdin());
    if (codes) py.print(core.personOnlyMessage(codes));
  },
  // The block message when the command (stdin) searches the mxcli binary (harness-core isBinarySearch).
  // The block message when the command (stdin) resolves an open question in an unattended run
  // (harness-core isSelfResolve). Run from the project.
  'self-resolve'() {
    const core = require('./plugins/harness-core.cjs');
    if (core.isSelfResolve(process.cwd(), py.readStdin())) py.print(core.SELF_RESOLVE);
  },
  // The block message when the command (stdin) captures a requirement against the frozen scope or
  // asks for a feature the request never named (plugins/capture_guard.cjs). Run from the project.
  'capture-block'() {
    const message = require('./plugins/harness-core.cjs').captureBlock(process.cwd(), py.readStdin());
    if (message) py.print(message);
  },
  // The block message when the command (stdin) installs a Marketplace widget from a publisher other
  // than Mendix or Mendixlabs (harness-core widgetPublisherBlock). Run from the project.
  'widget-publisher'() {
    const message = require('./plugins/harness-core.cjs').widgetPublisherBlock(process.cwd(), py.readStdin());
    if (message) py.print(message);
  },
  'binary-search'() {
    const core = require('./plugins/harness-core.cjs');
    if (core.isBinarySearch(py.readStdin())) py.print(core.BINARY_SEARCH);
  },
  // After a tool call (stdin: a Claude-shaped payload, or Cursor's): "run this new test now" when the
  // call wrote a tests/verify-*.test.sh that has never run (harness-core newTestNote). Run from the project.
  'new-test'() {
    const core = require('./plugins/harness-core.cjs');
    let payload;
    try { payload = JSON.parse(py.readStdin() || '{}'); } catch (e) { return; }
    const input = (payload && (payload.tool_input || payload.input || payload.arguments)) || {};
    const tool = String((payload && (payload.tool_name || payload.tool)) || (input.command ? 'bash' : 'write'));
    const note = core.newTestNote(process.cwd(), tool, input);
    if (note) py.print(note);
  },
  // The block message when the command (stdin) reads the harness's own code (harness-core readsHarnessSource).
  'harness-source'() {
    const core = require('./plugins/harness-core.cjs');
    if (core.readsHarnessSource('bash', { command: py.readStdin() })) py.print(core.HARNESS_SOURCE);
  },
  // The block message when a step before the exec writes one of its scripts.
  // heredoc-script: the command on stdin writes one script with a quoted heredoc and execs it --
  // writes the file and prints its path (harness-core heredocScript); prints "unquoted <path>" when
  // the delimiter is bare; nothing for any other command.
  'heredoc-script'() {
    const core = require('./plugins/harness-core.cjs');
    const found = core.heredocScript(py.readStdin());
    if (!found) return;
    if (found.unquoted) { py.print('unquoted ' + found.unquoted); return; }
    core.writeHeredocScript(process.cwd(), found);
    py.print(found.path);
  },
  // heredoc-put-back / heredoc-drop-note: after the precheck of a `cat >>` heredoc (harness-core).
  'heredoc-put-back'() { require('./plugins/harness-core.cjs').putHeredocBack(process.cwd()); },
  'heredoc-drop-note'() { require('./plugins/harness-core.cjs').dropHeredocNote(process.cwd()); },
  // saved-script-note <script>...: the command on stdin was refused by the precheck -- where its script
  // is, and to fix the named lines there and exec it alone (harness-core savedScriptNote).
  'saved-script-note'(...scripts) {
    const core = require('./plugins/harness-core.cjs');
    const command = py.readStdin();
    const found = core.heredocScript(command);
    py.print(core.savedScriptNote(command, scripts, found && !found.unquoted ? found : null).replace(/\n$/, ''));
  },
  // unquoted-heredoc-message <path>: the refusal for a bare delimiter.
  'unquoted-heredoc-message'(path) {
    py.print(require('./plugins/harness-core.cjs').HEREDOC_UNQUOTED(path));
  },
  // save-request: the prompt in the hook's JSON on stdin (prompt, user_prompt or text) saved word for
  // word to docs/brain/requests/NN.md of the project (harness-core saveRequest); prints the file.
  'save-request'() {
    const data = load();
    const text = get(data, 'prompt', '') || get(data, 'user_prompt', '') || get(data, 'text', '');
    const root = process.env.CLAUDE_PROJECT_DIR || process.env.CURSOR_PROJECT_DIR || process.cwd();
    const file = require('./plugins/harness-core.cjs').saveRequest(root, typeof text === 'string' ? text : '');
    if (file) py.print(file);
  },
  'script-written'(...scripts) {
    const text = py.readStdin();
    const m = re.search(EXEC, text);
    if (!m) return;
    const before = text.slice(0, m.start());
    const writes = re.search(String.raw`<<|(^|[\s;&|(])(mv|cp|tee|rm|ln|rsync|install|patch|ed|perl|python3?|node|ruby|git)\s|(^|[\s;&|(])sed\s+(-[a-zA-Z]*\s+)*-i`, before);
    for (const script of scripts) {
      const name = script.split('/').pop();
      const redirected = re.search(String.raw`>>?\s*\S*` + re.escape(name), before);
      if (redirected || (writes && (before.includes(script) || before.includes(name)))) {
        const [written, target] = require('./plugins/command_guards.cjs').writtenAndTarget(script, text.slice(m.start()), before);
        py.print(`Blocked: a step before the exec writes ${written} (an edit, a move or a new file), and the precheck runs before the command -- it would check the old file, or none. Nothing in this command ran. Run that step on its own, then \`./mxcli exec ${target}\` as its own command.`);
        break;
      }
    }
  },
  // The project's own modules from `SHOW MODULES --json`.
  modules() {
    const rows = load();
    if (!Array.isArray(rows)) return;
    for (const row of rows) {
      if (!isDict(row)) return;
      const source = or(row.Source, '');
      if (typeof source !== 'string') return;
      if (!py.strip(source) && !['System', 'MyFirstModule', 'MxTest'].includes(row.Module)) {
        if (!('Module' in row)) return;
        py.print(row.Module);
      }
    }
  },
  // sha256 of stdin's bytes, hex; the first <n> characters when given.
  sha256(n) {
    const digest = crypto.createHash('sha256').update(py.readStdinBytes()).digest('hex');
    py.print(n ? digest.slice(0, Number(n)) : digest);
  },
};

const [name, ...args] = process.argv.slice(2);
if (!Object.prototype.hasOwnProperty.call(tools, name)) {
  process.stderr.write(`hook_tool.cjs: no subcommand ${name}; one of ${Object.keys(tools).join(', ')}\n`);
  process.exit(2);
}
tools[name](...args);
