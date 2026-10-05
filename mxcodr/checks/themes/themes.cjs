#!/usr/bin/env node
// The app themes the installer offers, read from catalog.json beside this file.
//
//     themes.cjs list [--plain]     one row per theme: number, name, a slice of the app in its colours
//     themes.cjs resolve <choice>   the theme name for a number or name, or nothing (exit 1)
//     themes.cjs source <name>      "none" (Mendix's Atlas), "builtin", or the path of the bundle's <name>.css
//     themes.cjs skin <name>        the path of the bundle's <name>.skin.scss (its frame), if it has one
//     themes.cjs frame <name> <app>  write the current frame into <app>'s scaffold partial of that theme
//     themes.cjs preview            the path of preview.html
//     themes.cjs logo <name> <app>  copy the mx-codr mark in that theme's colours into <app>/theme/web/
//
// Colours are 24-bit when COLORTERM says so, else the nearest of the 256-colour palette;
// --plain (or NO_COLOR) prints names and descriptions only.
'use strict';
const fs = require('fs');
const path = require('path');
const py = require('../py_compat.cjs');

const HERE = __dirname;

const catalog = () => JSON.parse(fs.readFileSync(path.join(HERE, 'catalog.json'), 'utf8'));

function colour(hexcode, layer) {
  const h = hexcode.replace(/^#+/, '');
  const r = parseInt(h.slice(0, 2), 16), g = parseInt(h.slice(2, 4), 16), b = parseInt(h.slice(4, 6), 16);
  if (['truecolor', '24bit'].includes(process.env.COLORTERM || '')) return `\x1b[${layer};2;${r};${g};${b}m`;
  const q = v => Math.floor((v * 5) / 255);
  return `\x1b[${layer};5;${16 + 36 * q(r) + 6 * q(g) + q(b)}m`;
}
const bg = hexcode => colour(hexcode, 48);
const fg = hexcode => colour(hexcode, 38);
const pad = (text, width) => text + ' '.repeat(Math.max(0, width - [...text].length));

function listThemes(plain) {
  const reset = '\x1b[0m', bold = '\x1b[1m', grey = '\x1b[38;5;245m';
  catalog().forEach((theme, i) => {
    const number = i + 1;
    const t = theme.light, desc = theme.description.split(' -- ').join(' — ');
    const dflt = number === 1 ? '  (default)' : '';
    if (plain) {
      py.print(`    ${number}  ${pad(theme.name, 8)} ${desc}${dflt}`);
      return;
    }
    // A slice of the app: the side menu, the top bar, the page, a selected row, the Save button.
    const top = (theme.frame || {}).top || t.rail;
    const swatch = bg(t.rail) + fg(t['rail-ink-active']) + ' ▤ ' + reset +
      bg(top) + fg('#ffffff') + ' Your App ' + reset +
      bg(t.ground) + fg(t.ink) + ' Orders ' + reset +
      bg(t['surface-selected']) + fg(t.ink) + ' INV-042 ' + reset +
      bg(t.brand) + fg(t['brand-ink']) + ' Save ' + reset;
    py.print(`    ${bold}${number}${reset}  ${pad(theme.name, 8)} ${swatch}  ${grey}${desc}${dflt}${reset}`);
  });
}

function resolve(choice) {
  const themes = catalog();
  choice = py.strip(choice || '').toLowerCase();
  if (!choice) return themes[0].name;
  if (/^\p{Nd}+$/u.test(choice) && Number(choice) >= 1 && Number(choice) <= themes.length) return themes[Number(choice) - 1].name;
  for (const theme of themes) if (theme.name === choice) return theme.name;
  return '';
}

function copyTree(source, target) {
  fs.mkdirSync(target, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name), to = path.join(target, entry.name);
    if (entry.isDirectory()) copyTree(from, to);
    else fs.copyFileSync(from, to);
  }
}

const USAGE = `The app themes the installer offers, read from catalog.json beside this file.

    themes.cjs list [--plain]     one row per theme: number, name, a slice of the app in its colours
    themes.cjs resolve <choice>   the theme name for a number or name, or nothing (exit 1)
    themes.cjs source <name>      "none" (Mendix's Atlas), "builtin", or the path of the bundle's <name>.css
    themes.cjs skin <name>        the path of the bundle's <name>.skin.scss (its frame), if it has one
    themes.cjs frame <name> <app>  write the current frame into <app>'s scaffold partial of that theme
    themes.cjs preview            the path of preview.html
    themes.cjs logo <name> <app>  copy the mx-codr mark in that theme's colours into <app>/theme/web/

Colours are 24-bit when COLORTERM says so, else the nearest of the 256-colour palette;
--plain (or NO_COLOR) prints names and descriptions only.`;

function main(argv) {
  const command = argv[0] || '';
  if (command === 'list') {
    listThemes(argv.includes('--plain') || Boolean(process.env.NO_COLOR));
    return 0;
  }
  if (command === 'resolve' && argv.length <= 2) {
    const name = resolve(argv.length === 2 ? argv[1] : '');
    if (name) py.print(name);
    return name ? 0 : 1;
  }
  if (command === 'source' && argv.length === 2) {
    for (const theme of catalog()) {
      if (theme.name === argv[1]) {
        const source = theme.source;
        py.print(['none', 'builtin'].includes(source) ? source : path.join(HERE, source));
        return 0;
      }
    }
    return 1;
  }
  if (command === 'skin' && argv.length === 2) {
    const file = path.join(HERE, argv[1] + '.skin.scss');
    if (py.isfile(file)) {
      py.print(file);
      return 0;
    }
    return 1;
  }
  if (command === 'frame' && argv.length === 3) {
    // The frame is appended to the scaffold's own partial once, when the theme is created. A
    // project that already had the theme kept the frame of the bundle it was created with, so a
    // fix to the frame (control heights, 2026-10-05) never reached it. Replace it on every apply:
    // everything from the frame's first line to the end of the partial is the old frame.
    const skin = path.join(HERE, argv[1] + '.skin.scss');
    const partial = path.join(argv[2], 'theme', 'mxcli-themes', argv[1], 'files', 'theme', 'web', `_mxcli-${argv[1]}.scss`);
    if (!py.isfile(skin) || !py.isfile(partial)) return 1;
    const frame = fs.readFileSync(skin, 'utf8');
    const text = fs.readFileSync(partial, 'utf8');
    const start = text.search(/^\/\/ -+\n\/\/ mx-codr frame for /m);
    const kept = start < 0 ? text.replace(/\n*$/, '\n') : text.slice(0, start);
    fs.writeFileSync(partial, kept + (kept.endsWith('\n\n') || kept === '' ? '' : '\n') + frame);
    return 0;
  }
  if (command === 'logo' && argv.length === 3) {
    // The browser and home-screen icons, the sign-in logo and Atlas's top bar logo, by the
    // names mxbuild copies from theme/web/ over its own (logos/<name>/ mirrors theme/web/).
    const source = path.join(HERE, 'logos', argv[1]);
    const web = path.join(argv[2], 'theme', 'web');
    if (!py.isdir(source) || !py.isdir(web)) return 1;
    copyTree(source, web);
    // `mxcli run --watch` copies theme/web/ only when a stylesheet changes: nudge one.
    const mainScss = path.join(web, 'main.scss');
    if (py.isfile(mainScss)) {
      const now = new Date();
      fs.utimesSync(mainScss, now, now);
    }
    return 0;
  }
  if (command === 'preview') {
    py.print(path.join(HERE, 'preview.html'));
    return 0;
  }
  process.stderr.write(USAGE + '\n');
  return 2;
}

process.exitCode = main(process.argv.slice(2));
