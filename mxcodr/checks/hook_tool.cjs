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
  // Cursor's deny for a failed precheck.
  deny() {
    py.print(py.jsonDumps({
      permission: 'deny',
      userMessage: 'mxcli exec blocked: the script would break the build (see the agent message).',
      agentMessage: py.readStdin(),
    }));
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
    if (re.search(String.raw`Nothing was written|Refusing to execute|^\s*(Parse error|Error|error)\b`, text, 'm')) {
      py.print('exec: FAILED -- mxcli wrote nothing; the reason is in its output above. Fix the script and exec it again.');
    } else if (re.search(String.raw`^\s*(Created|Modified|Replaced|Updated|Dropped|Altered|Moved|Granted|Revoked)\b|already in sync`, text, 'm')) {
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
  // The .mdl words of a command, one per line, $PWD resolved, globs expanded.
  scripts() {
    const seen = new Set();
    for (let word of shellWords(py.readStdin())) {
      if (!word.endsWith('.mdl') || seen.has(word)) continue;
      // `$PWD/mdlsource/x.mdl` is the project itself, not a loop variable.
      for (const v of ['${PWD}/', '$PWD/', '$(pwd)/']) {
        if (word.startsWith(v)) word = process.cwd() + '/' + word.slice(v.length);
      }
      seen.add(word);
      const matches = expand(word);
      py.print(matches.length ? matches.join('\n') : word);
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
      if (!trivial.match(py.strip(step))) {
        py.print('Nothing in this command ran, the steps before the exec included (an edit there never happened): the script was checked as it is on disk. Run those steps on their own, then the exec as its own command.');
        break;
      }
    }
  },
  // The block message when a step before the exec writes one of its scripts.
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
        py.print(`Blocked: a step before the exec writes ${script} (an edit, a move or a new file), and the precheck runs before the command -- it would check the old file, or none. Nothing in this command ran. Run that step on its own, then \`./mxcli exec ${script}\` as its own command.`);
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
