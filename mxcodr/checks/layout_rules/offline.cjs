// Offline profiles (PWAs that work without a network).
//   OFFLINE01  an offline profile in an app whose build registers no service worker: the
//              profile has no Progressive web app settings (mxcli 0.28 writes them with the
//              `progressive web app` clause of create or modify navigation; 0.27 and before had no
//              syntax, and Studio Pro shows them greyed out for an offline profile), so no page
//              opens without a network. Read from the built index.js.
//   OFFLINE02  an offline profile that synchronizes no entity: it downloads nothing and shows an
//              empty app.
//   OFFLINE03  an app with an offline profile and no test that cuts the network (go_offline()).
// Measured on OfflineLab (2026-10-10): every one of these passed mxcli check, exec and mx check.
// The rules for phone and tablet layouts (PHONE01-05, TABS01) are in phone.cjs.
'use strict';
const fs = require('fs');
const path = require('path');

const PROFILE_RE = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?navigation\s+(\w+)/i;
const SYNC_RE = /^\s*sync\s+([\w.]+)\s+(all|online|where\b|never|none)/i;
const OFFLINE_KINDS = new Set(['ResponsiveOffline', 'PhoneOffline', 'TabletOffline']);

// {profile: [[entity, mode], ...]} for the offline profiles of DESCRIBE NAVIGATION output.
function offlineProfiles(navigation) {
  const out = new Map();
  let profile = '';
  for (const line of String(navigation || '').split(/\r?\n/)) {
    const p = PROFILE_RE.exec(line);
    if (p) { profile = OFFLINE_KINDS.has(p[1]) ? p[1] : ''; if (profile) out.set(profile, []); continue; }
    const s = profile && SYNC_RE.exec(line);
    if (s) out.get(profile).push([s[1], s[2].toLowerCase()]);
  }
  return out;
}

// True when some test in <testsDir> calls go_offline() on a line that is not a comment.
function testGoesOffline(testsDir) {
  let names = [];
  try { names = fs.readdirSync(testsDir).filter(n => /^verify-.*\.test\.sh$/.test(n)); } catch { return false; }
  return names.some(n => fs.readFileSync(path.join(testsDir, n), 'utf8').split(/\r?\n/)
    .some(l => !/^\s*(#|\/\/)/.test(l) && /\bgo_offline\s*\(/.test(l)));
}

// [{check, line, message}] -- webIndex: the built deployment/web/index.js text ('' when not built
// here, e.g. in Docker mode: OFFLINE01 is then not judged); testsDir: the project's tests/.
function offlineFindings(navigation, webIndex, testsDir) {
  const out = [];
  const profiles = offlineProfiles(navigation);
  if (!profiles.size) return out;
  const names = [...profiles.keys()].join(', ');
  if (/"registerServiceWorker"\s*:\s*false/.test(webIndex || '')) {
    out.push({ check: 'OFFLINE01', line: 0, message: `navigation profile ${names} is offline, but the built app registers no` +
      ' service worker ("registerServiceWorker": false in deployment/web/index.js), so no page opens without a network:' +
      ' the profile has no Progressive web app settings. Give it some: DESCRIBE NAVIGATION ' + [...profiles.keys()][0] +
      ', then create or modify navigation <profile> progressive web app ( Precaching: true ); (the clause alone leaves the' +
      ' rest of the profile alone; mxcli 0.28 warns when an offline profile lacks it), restart the app so it is built' +
      ' again, and run the gate. Do not build around it.' });
  }
  for (const [profile, configs] of profiles) {
    if (configs.some(([, mode]) => mode === 'all' || mode === 'where')) continue;
    out.push({ check: 'OFFLINE02', line: 0, message: `navigation profile ${profile} synchronizes no entity, so the device` +
      ' downloads nothing and shows an empty app -- give each entity its pages show a mode in the profile:' +
      ` create or modify navigation ${profile} ... sync ( sync Module.Entity all; sync Module.Other where [Owner = '[%CurrentUser%]']; )` +
      ' (DESCRIBE NAVIGATION first and keep the rest)' });
  }
  if (testsDir && !testGoesOffline(testsDir)) {
    out.push({ check: 'OFFLINE03', line: 0, message: `navigation profile ${names} works offline, and no test cuts the network:` +
      ` write one that opens it (open_app("${[...profiles.keys()][0]}")), calls go_offline(), does the work the user does` +
      ' without a network, checks with oql_count that the server has nothing yet, then go_online() and sync_now() and checks' +
      ' that it arrived (skill test-first-delivery, "Phone and offline profiles")' });
  }
  return out;
}

module.exports = { PROFILE_RE, offlineProfiles, offlineFindings, testGoesOffline };
