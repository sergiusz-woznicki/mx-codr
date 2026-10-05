// Merge the harness hooks into .claude/settings.local.json; adds only missing entries.
'use strict';
const fs = require('fs');
const { dumps, load } = require('./json_file.cjs');

const path = process.argv[2];
let settings;
try {
  settings = load(path) || {};
} catch (error) {
  // Replacing it would throw away whatever the developer had; the Codex and Cursor
  // mergers below refuse for the same reason.
  process.stderr.write(`   !! ${path} is not valid JSON (${error.message}); leaving it alone. Fix it and re-run.\n`);
  process.exit(1);
}
if (!('hooks' in settings)) settings.hooks = {};
const hooks = settings.hooks;
const wanted = [
  ['UserPromptSubmit', { hooks: [{ type: 'command', command: 'bash tools/mdl-checks/hooks/remind-skills.sh' }] }],
  // 180s: the precheck copies the model and runs mx check on it (~6s on a small app).
  ['PreToolUse', { matcher: 'Bash', hooks: [{ type: 'command', command: 'bash tools/mdl-checks/hooks/before-mxcli-exec.sh', timeout: 180 }] }],
  // tests/harness.env is the person's: the session may not flip a gate switch.
  ['PreToolUse', { matcher: 'Bash|Edit|Write|MultiEdit|NotebookEdit', hooks: [{ type: 'command', command: 'bash tools/mdl-checks/hooks/guard-harness-env.sh', timeout: 30 }] }],
  ['PostToolUse', { matcher: 'Bash', hooks: [{ type: 'command', command: 'bash tools/mdl-checks/hooks/after-mxcli-exec.sh' }] }],
];
for (const [event, entry] of wanted) {
  if (!(event in hooks)) hooks[event] = [];
  const existing = hooks[event];
  const key = dumps(entry, null, true);
  if (!existing.some(e => dumps(e, null, true) === key)) existing.push(entry);
}
fs.writeFileSync(path, dumps(settings, 2));
