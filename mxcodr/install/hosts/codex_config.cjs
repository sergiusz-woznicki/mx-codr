// Put a first-turn reminder to trust the project hooks into .codex/config.toml, unless it already
// has developer_instructions. Prints `added` or `existing`.
'use strict';
const fs = require('fs');

const path = process.argv[2];
let existing = '';
try {
  // Python read it in text mode, which turns \r\n into \n; keep that.
  existing = fs.readFileSync(path, 'utf8').replace(/\r\n?/g, '\n');
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

if (/^[ \t]*developer_instructions[ \t]*=/m.test(existing)) {
  process.stdout.write('existing\n');
  process.exit(0);
}

const reminder = `# Codex hook trust reminder
developer_instructions = """
After the first user prompt in each new Codex session for this repository, include one short reminder to open \`/hooks\` and review or trust the project hooks if they are new or changed. Do not repeat the reminder later in the same session.
"""

`;
fs.writeFileSync(path, reminder + existing);
process.stdout.write('added\n');
