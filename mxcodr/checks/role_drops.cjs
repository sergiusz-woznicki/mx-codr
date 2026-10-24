// SCRIPT02, the precheck's check of what a script drops: a user role something still needs.
//
//   node role_drops.cjs <demo-users.json> <user-roles.json> <script.mdl>...
//
// Two ways a `drop user role` broke a build that `mx check` and `mxcli check` both pass or find only
// after a 20-40 s run on a copy of the model (invoice-chase, 2026-10-24, five failed boots):
//   - the role Administrator belongs to the built-in administrator (MxAdmin): without it mxbuild stops at
//     the first build with "Object reference not set to an instance of an object", and mx check says 0 errors;
//   - a demo user still holds the role: CE1613 "The selected user role 'X' no longer exists".
// Both are read from the scripts and two answers of the model (SHOW DEMO USERS, SHOW USER ROLES, as JSON).
// A script that also creates the role again, or drops or creates the demo user, is left alone: the end
// state is what the build sees. Prints one finding per line; nothing when all is well. Never fails.
'use strict';
const fs = require('fs');

// Comments out, so a `drop user role` in a comment is not one.
function statements(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, ' ').split(/\r?\n/)
    .filter(line => !/^\s*(--|\/\/)/.test(line)).join('\n');
}

const NAME = String.raw`(?:"([^"]+)"|'([^']+)'|([A-Za-z_][\w.]*))`;
function names(text, pattern) {
  const out = [];
  for (const m of text.matchAll(new RegExp(pattern, 'gi'))) out.push(m[1] || m[2] || m[3]);
  return out;
}

// roleDropFindings(scriptTexts, demoUsers, userRoles) -> [message]
//   demoUsers: rows of SHOW DEMO USERS --json ({"User Name", "User Roles": "A, B"}); userRoles: rows of SHOW USER ROLES --json.
function roleDropFindings(scriptTexts, demoUsers, userRoles) {
  const text = scriptTexts.map(statements).join('\n');
  const lower = list => list.map(n => n.toLowerCase());
  const dropped = names(text, String.raw`\bdrop\s+user\s+role\s+(?:if\s+exists\s+)?` + NAME);
  if (!dropped.length) return [];
  const created = lower(names(text, String.raw`\bcreate\s+(?:or\s+(?:modify|replace)\s+)?user\s+role\s+` + NAME));
  const demoTouched = lower([
    ...names(text, String.raw`\bdrop\s+demo\s+user\s+(?:if\s+exists\s+)?` + NAME),
    ...names(text, String.raw`\bcreate\s+(?:or\s+(?:modify|replace)\s+)?demo\s+user\s+` + NAME)]);
  const existing = lower((Array.isArray(userRoles) ? userRoles : []).map(r => String(r.Name || '')));
  const out = [];
  for (const role of [...new Set(dropped)]) {
    const key = role.toLowerCase();
    if (created.includes(key)) continue;
    if (key === 'administrator' && existing.includes(key)) {
      out.push(`drop user role ${role}: that is the role of the built-in administrator (MxAdmin). Without it mxbuild stops at the first ` +
        'build with "Object reference not set to an instance of an object" (no CE code, and mx check says 0 errors) and the app does not boot. ' +
        'Keep a user role named Administrator: leave this drop out, and give that role the module roles the owner needs');
    }
    for (const user of Array.isArray(demoUsers) ? demoUsers : []) {
      const name = String(user['User Name'] || '');
      const roles = lower(String(user['User Roles'] || '').split(',').map(r => r.trim()));
      if (!roles.includes(key) || demoTouched.includes(name.toLowerCase())) continue;
      out.push(`drop user role ${role}: the demo user '${name}' still holds it (CE1613 "The selected user role '${role}' no longer exists"). ` +
        `Drop or recreate the demo user in this script: drop demo user '${name}'; ... create demo user '${name}' ... with another role`);
    }
  }
  return out;
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return []; }
}

if (require.main === module) {
  const [demoFile, rolesFile, ...scripts] = process.argv.slice(2);
  const texts = [];
  for (const file of scripts) { try { texts.push(fs.readFileSync(file, 'utf8')); } catch { /* unreadable: the precheck says so */ } }
  for (const line of roleDropFindings(texts, readJson(demoFile), readJson(rolesFile))) console.log(`  ${line}`);
}

module.exports = { roleDropFindings };
