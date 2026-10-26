// own_port.cjs -- the app's own address in its constants: a REST URL constant that points the app at
// itself (its own published REST service, a mock of an outside system) names the model's own port, the
// HttpPortNumber of the configuration the app runs with, and every runner maps that port to the one it
// really listens on. The gate boots on APP_PORT, which is not the model's port, so a run that wrote
// APP_PORT into the constant passed its own tests and called the wrong port for anyone who ran the app
// from its model (b2b-orders hb1 and hb2, 2026-10-25: http://localhost:8090 against HttpPortNumber 8080).
// Measured on mxcli 0.28 and Mendix 11.12: the runtime's own root URL is no way out --
// Core.getConfiguration().getApplicationRootUrl() returns '' under `mxcli test --local`, and
// `mxcli run --local --app-port` does not derive it from the port; no expression token holds it (CE0117).
//
//   node own_port.cjs boot-constants <app dir> <mpr> <app port>
//     `--constant` arguments for `mxcli run --local`, one per line: every String constant whose value
//     (the configuration's, else its default) is http(s)://localhost|127.0.0.1:<model port>..., with
//     the port replaced by <app port>. Nothing when the ports are the same or the model cannot be read.
'use strict';

const LOCAL_URL = /^(https?:\/\/(?:localhost|127\.0\.0\.1))(?::(\d+))?(.*)$/i;

// The configuration `mxcli run --local` boots with (the only one, else 'Default') from `describe settings`:
// {name, httpPort (number or null), overrides: {Constant: value}}.
function configurationOf(settings) {
  const text = String(settings || '');
  const configs = [...text.matchAll(/create\s+or\s+modify\s+configuration\s+'([^']+)'\s*\(([\s\S]*?)\n\);/gi)]
    .map(m => ({ name: m[1], body: m[2] }));
  const chosen = configs.length === 1 ? configs[0] : configs.find(c => c.name === 'Default') || configs[0];
  if (!chosen) return { name: '', httpPort: null, overrides: {} };
  const port = /\bHttpPortNumber:\s*(\d+)/i.exec(chosen.body);
  const overrides = {};
  for (const m of text.matchAll(/alter\s+settings\s+constant\s+'([^']+)'\s+value\s+'((?:[^']|'')*)'\s+in\s+configuration\s+'([^']+)'/gi)) {
    if (m[3] === chosen.name) overrides[m[1]] = m[2].replace(/''/g, "'");
  }
  return { name: chosen.name, httpPort: port ? Number(port[1]) : null, overrides };
}

// A URL on this machine: {base, port (number; 80/443 when left out), rest}, or null.
function localUrl(value) {
  const m = LOCAL_URL.exec(String(value || '').trim());
  if (!m) return null;
  return { base: m[1], port: m[2] ? Number(m[2]) : (/^https/i.test(m[1]) ? 443 : 80), written: Boolean(m[2]), rest: m[3] };
}

// [{name, value}] of the constants: value = the configuration's, else the default.
function constantValues(rows, configuration) {
  return rows.map(r => {
    const name = r.QualifiedName || r['Qualified Name'] || '';
    const fallback = r.DefaultValue !== undefined ? r.DefaultValue : r.Default;
    const value = Object.prototype.hasOwnProperty.call(configuration.overrides, name) ? configuration.overrides[name] : fallback;
    return { name, value: String(value == null ? '' : value) };
  }).filter(c => c.name);
}

// `Mod.C=value` for each constant that names the model's own port, moved to <appPort>.
function bootConstants(rows, settings, appPort) {
  const configuration = configurationOf(settings);
  const port = Number(appPort);
  if (!configuration.httpPort || !port || configuration.httpPort === port) return [];
  const out = [];
  for (const c of constantValues(rows, configuration)) {
    const url = localUrl(c.value);
    if (url && url.written && url.port === configuration.httpPort) out.push(`${c.name}=${url.base}:${port}${url.rest}`);
  }
  return out;
}

function main(argv) {
  const [command, appDir, mpr, appPort] = argv;
  if (command !== 'boot-constants' || !appDir || !mpr || !appPort) {
    process.stderr.write('usage: own_port.cjs boot-constants <app dir> <mpr> <app port>\n');
    return 2;
  }
  try {
    const { mxcli } = require('./mxcli_client.cjs');
    const settings = mxcli(appDir, mpr, 'describe settings');
    const rows = mxcli(appDir, mpr, 'show constants', true);
    for (const line of bootConstants(rows, settings, appPort)) process.stdout.write(line + '\n');
  } catch { /* the model cannot be read: boot with the model's own values */ }
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { configurationOf, localUrl, constantValues, bootConstants };
