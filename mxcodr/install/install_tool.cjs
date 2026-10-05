// The small jobs the installer gives to a script, one subcommand each. Each is the Node port of a
// Python snippet that sat inline in install/*.sh; they print what the snippet printed.
//
//     node install_tool.cjs <subcommand> [args]
//
//   mpr-version <file.mpr>          the Mendix version a project file was saved with
//   app-mx-version <app>            the same, for the first .mpr in <app>
//   mxbuild-note <app> <windows?>   a line when mx check has no mxbuild/Studio Pro for that version
//   fix-browser <cli.config.json>   repoint a playwright-cli config whose chromium is gone
//   release-asset <asset>           "<tag> <sha256> <url>" of an asset in a GitHub release (stdin)
//   sha256-file <file>              a file's SHA-256
//   powershell-encode <script>      base64 of the script as UTF-16LE, for -EncodedCommand
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const py = require('../checks/py_compat.cjs');

// The project file is SQLite; node:sqlite prints an ExperimentalWarning on load, which is not
// ours to show. No node:sqlite (Node before 22.5): the version is unknown, as when Python failed.
function metadataRow(file, sql) {
  process.removeAllListeners('warning');
  let sqlite;
  try {
    sqlite = require('node:sqlite');
  } catch {
    return undefined;
  }
  try {
    const db = new sqlite.DatabaseSync(file, { readOnly: true });
    try {
      const row = db.prepare(sql).get();
      return row ? Object.values(row) : undefined;
    } finally {
      db.close();
    }
  } catch {
    return undefined;
  }
}
const firstMpr = app => py.glob(py.join(app, '*.mpr'))[0];

const tools = {
  'mpr-version'(file) {
    const row = metadataRow(file, 'select _ProductVersion from _MetaData');
    if (row && row.length) py.print(row[0]);
    else process.exitCode = 1;
  },
  'app-mx-version'(app) {
    const mpr = firstMpr(app);
    if (!mpr) return;
    const row = metadataRow(mpr, 'select * from _MetaData limit 1');
    if (row && row.length > 1) py.print(row[1]);
  },
  'mxbuild-note'(app, windows) {
    const mpr = firstMpr(app);
    if (!mpr) return;
    const row = metadataRow(mpr, 'select * from _MetaData limit 1');
    if (!row || row.length < 2) return;
    const version = py.pyStr(row[1]);
    let cached = path.join(os.homedir(), '.mxcli', 'mxbuild', version);
    if (windows === '1') {
      // Studio Pro installs in two places; 10.x and 11.x default to the per-user one.
      const roots = [py.join(process.env.ProgramFiles || 'C:\\Program Files', 'Mendix'),
        py.join(process.env.LOCALAPPDATA || '', 'Programs', 'Mendix')];
      cached = '';
      for (const root of roots) {
        if (!root) continue;
        const candidate = py.join(root, version, 'modeler');
        if (py.isdir(candidate)) { cached = candidate; break; }
      }
      cached = cached || py.join(roots[0], version, 'modeler');
    }
    if (!py.isdir(cached)) {
      if (py.WIN || windows === '1') {
        py.print(`Mendix ${version}: \`mx check\` needs Studio Pro ${version} -- the Mendix CDN's mxbuild is ` +
          'Linux-only, so `mxcli setup mxbuild` cannot help here.');
      } else {
        py.print(`Mendix ${version}, no mxbuild cached -- \`mx check\` will not run until: ` +
          `./mxcli setup mxbuild -p ${py.basename(mpr)}`);
      }
    }
  },
  'fix-browser'(file) {
    let config;
    try {
      config = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      return;
    }
    const browser = config && typeof config === 'object' && 'browser' in config ? config.browser : {};
    const options = browser && typeof browser === 'object' && 'launchOptions' in browser ? browser.launchOptions : {};
    if (!options || typeof options !== 'object') return;
    const current = options.executablePath;
    if (!current || py.exists(current)) return;
    // Prefer a headless shell Playwright has already downloaded; otherwise let it choose.
    const home = os.homedir();
    const roots = [path.join(home, 'Library/Caches/ms-playwright'), path.join(home, '.cache/ms-playwright'),
      py.join(process.env.LOCALAPPDATA || '', 'ms-playwright')];
    const candidates = [];
    for (const root of roots) {
      if (!root) continue;
      for (const suffix of ['chrome-headless-shell', 'chrome-headless-shell.exe']) {
        candidates.push(...py.sorted(py.glob(py.join(root, 'chromium_headless_shell-*', 'chrome-headless-shell-*', suffix))));
      }
    }
    let replacement;
    if (candidates.length) {
      options.executablePath = candidates[candidates.length - 1];
      replacement = candidates[candidates.length - 1];
    } else {
      delete options.executablePath;
      replacement = "Playwright's own browser";
    }
    fs.writeFileSync(file, py.jsonDumps(config, { indent: 2 }));
    py.print(`${py.pyStr(current)} -> ${replacement}`);
  },
  'release-asset'(asset) {
    let data;
    try {
      data = JSON.parse(py.readStdin());
    } catch {
      process.exit(1);
    }
    const assets = (data && data.assets) || [];
    for (const item of Array.isArray(assets) ? assets : []) {
      const digest = py.pyStr(item.digest || '');
      if (item.name === asset && digest.startsWith('sha256:')) {
        py.print(py.pyStr('tag_name' in data ? data.tag_name : ''), digest.slice(7),
          py.pyStr('browser_download_url' in item ? item.browser_download_url : ''));
        return;
      }
    }
    process.exit(1);
  },
  'sha256-file'(file) {
    py.print(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'));
  },
  'powershell-encode'(script) {
    py.print(Buffer.from(script, 'utf16le').toString('base64'));
  },
};

const [name, ...args] = process.argv.slice(2);
if (!Object.prototype.hasOwnProperty.call(tools, name)) {
  process.stderr.write(`install_tool.cjs: no subcommand ${name}; one of ${Object.keys(tools).join(', ')}\n`);
  process.exit(2);
}
tools[name](...args);
