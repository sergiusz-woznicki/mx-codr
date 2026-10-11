// Offline profiles (PWAs that work without a network) and the menus of phone and tablet layouts.
//   OFFLINE01  an offline profile in an app whose build registers no service worker: the
//              profile has no Progressive web app settings (mxcli v0.25 writes none; Studio
//              Pro shows them greyed out and fixed for an offline profile, so the only repair
//              is deleting and re-adding the profile there), so no page opens without a
//              network. Read from the built index.js.
//   OFFLINE02  an offline profile that synchronizes no entity: it downloads nothing and shows an
//              empty app.
//   OFFLINE03  an app with an offline profile and no test that cuts the network (go_offline()).
//   PHONE01    a page whose layout shows a menu document whose items do nothing: Atlas's phone and
//              tablet layouts show Atlas_Core.Phone_Menu / Tablet_Menu, the template's Home,
//              Layouts, Templates and Widgets with no action, instead of the app's own menu.
//   PHONE02    a page the browser profile (Responsive) opens -- a home page or a menu item -- on a
//              Phone or Tablet layout: in a browser the user gets the phone's bottom bar instead of
//              the app's menu (measured on OfflineLab 2026-10-10: My jobs lost My account and the menu).
//   PHONE03    a page on a Phone or Tablet layout that shows a data grid: on a phone its columns cut
//              every value to "J..." and "M..." (measured on OfflineLab 2026-10-10, 390 px); the
//              items belong in a list view of cards, each value on its own line.
//   PHONE04    an app on a Phone or Tablet layout whose compiled theme carries Atlas Core's broken
//              selector `.mx-scrollcontainer-fixed d .mx-scrollcontainer-middle` (Atlas Core 4.1.3, the
//              one Mendix 11.12.1's blank app ships; 4.3.7 has it right): the content region never scrolls by itself, so on a phone
//              the whole page scrolls and the bottom bar slides off the screen (measured on
//              OfflineLab 2026-10-11: with 30 lines the bar sat at 3067 px on an 844 px screen).
//   PHONE05    the same app's login form keeps Atlas Core's fixed `width: 400px` with no narrow-screen
//              rule: on a 390 px phone it touches the left edge and runs off the right one (every
//              Atlas version, 4.1.3 and 4.3.7 alike; measured on OfflineLab 2026-10-11).
// Measured on OfflineLab (2026-10-10): every one of these passed mxcli check, exec and mx check.
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
      ' the profile was written by mxcli without Progressive web app settings, and they cannot be set afterwards: Studio' +
      ' Pro shows them greyed out for an offline profile, and this mxcli has no syntax for them (mendixlabs/mxcli#1377).' +
      ' STOP and ask the person to delete the ' + names + ' profile(s) in Studio Pro (App Explorer > Navigation) and add' +
      ' them again there -- Studio Pro then stores its own settings -- save and close Studio Pro, and say so. Then re-apply' +
      ' the profile\'s home pages, menu and sync with create or modify navigation (it leaves the settings alone) and run' +
      ' the gate. Do not build around it.' });
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

// The menu documents a layout shows in a simple menu bar: {layout: [menu, ...]} from DESCRIBE LAYOUT.
function layoutMenus(text) {
  const out = new Map();
  let layout = '';
  for (const line of String(text || '').split(/\r?\n/)) {
    const l = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?layout\s+([\w.]+)/i.exec(line);
    if (l) { layout = l[1]; continue; }
    if (/^\s*create\s/i.test(line)) layout = '';
    const m = layout && /^\s*simplemenubar\b.*\bmenu\s*:\s*([\w.]+)/i.exec(line);
    if (m) { if (!out.has(layout)) out.set(layout, []); out.get(layout).push(m[1]); }
  }
  return out;
}

// {menu: {items, acting}} from DESCRIBE MENU: how many items it has and how many do something.
function menuItems(text) {
  const out = new Map();
  let menu = '';
  for (const line of String(text || '').split(/\r?\n/)) {
    const m = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?menu\s+([\w.]+)/i.exec(line);
    if (m) { menu = m[1]; out.set(menu, { items: 0, acting: 0 }); continue; }
    if (/^\s*create\s/i.test(line)) menu = '';
    if (!menu || !/^\s*menu\s+item\b/i.test(line)) continue;
    const e = out.get(menu);
    e.items++;
    if (/\bonclick\s*:\s*(?!nothing\b)\S/i.test(line)) e.acting++;
  }
  return out;
}

// PHONE01 over the pages (DESCRIBE PAGE lines) and the describes of their layouts and menus.
function phoneMenuFindings(pageLines, layoutText) {
  const menus = menuItems(layoutText);
  const shows = layoutMenus(layoutText);
  const byLayout = new Map();
  let page = '';
  for (const line of pageLines) {
    const p = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?page\s+([\w.]+)/i.exec(line);
    if (p) { page = p[1]; continue; }
    const l = page && /^\s*layout\s*:\s*([\w.]+)/i.exec(line);
    if (l) { if (!byLayout.has(l[1])) byLayout.set(l[1], []); byLayout.get(l[1]).push(page); page = ''; }
  }
  const out = [];
  for (const [layout, pages] of byLayout) {
    for (const menu of shows.get(layout) || []) {
      const m = menus.get(menu);
      if (!m || !m.items || m.acting) continue;
      const own = pages[0].split('.')[0];
      out.push({ check: 'PHONE01', line: 0, message: `${pages.length} page(s) on layout ${layout} (${pages.slice(0, 3).join(', ')}` +
        `${pages.length > 3 ? ' ...' : ''}) show the menu ${menu}, whose ${m.items} item(s) do nothing (the template's placeholder` +
        ` menu) -- give the app its own: create or modify menu ${own}.Phone_Menu { menu item 'Work' ( OnClick: show page ..., Icon: ... )` +
        ` menu item 'Log out' ( OnClick: sign out, Icon: Atlas_Core.Atlas_Filled.logout ) }, copy the layout into ${own}` +
        ` (describe layout ${layout}, rename it ${own}.Phone_Main, point its simplemenubar at ${own}.Phone_Menu, exec), and` +
        ` move onto it the pages only the phone or offline profiles open: alter page <Page> { set layout = ${own}.Phone_Main };` +
        ' a page the browser profile (Responsive) opens too stays on a web layout (PHONE02) (skill write-layouts)' });
    }
  }
  return out;
}

// PHONE02 over the navigation (DESCRIBE NAVIGATION), the pages (DESCRIBE PAGE lines) and the
// describes of their layouts: a page the browser profile opens must not sit on a phone or tablet layout.
// {layout: its layouttype (Phone, Tablet, Responsive...)} from DESCRIBE LAYOUT output.
function layoutKinds(layoutText) {
  const kinds = new Map();
  let layout = '';
  for (const line of String(layoutText || '').split(/\r?\n/)) {
    const l = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?layout\s+([\w.]+)/i.exec(line);
    if (l) { layout = l[1]; continue; }
    const t = layout && /\blayouttype\s*:\s*'?(\w+)/i.exec(line);
    if (t) { kinds.set(layout, t[1]); layout = ''; }
  }
  return kinds;
}

function webPhoneLayoutFindings(navigation, pageLines, layoutText) {
  const kinds = layoutKinds(layoutText);
  const layoutOf = new Map(), shows = new Map();
  let page = '', current = '';
  for (const line of pageLines) {
    const p = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?page\s+([\w.]+)/i.exec(line);
    if (p) { page = current = p[1]; shows.set(current, []); continue; }
    const l = page && /^\s*layout\s*:\s*([\w.]+)/i.exec(line);
    if (l) { layoutOf.set(page, l[1]); page = ''; }
    if (!current) continue;
    for (const m of line.matchAll(/\bshow(?:\s+|_)page\s+([\w.]+)/gi)) shows.get(current).push(m[1]);
  }
  // {page: [how the browser profile opens it]}; phone: the pages a phone, tablet or offline profile opens.
  const opened = new Map(), phone = new Set();
  let profile = '', web = false;
  for (const line of String(navigation || '').split(/\r?\n/)) {
    const p = PROFILE_RE.exec(line);
    if (p) { profile = p[1]; web = /^Responsive/i.test(profile); continue; }
    if (!profile) continue;
    if (!web) {
      for (const m of line.matchAll(/\b(?:home\s+page|page)\s+([\w.]+)/gi)) phone.add(m[1]);
      continue;
    }
    const home = /^\s*home\s+page\s+([\w.]+)(?:\s+for\s+(\w+))?/i.exec(line);
    // mdl 0 (`page X`, what check_layout reads) and mdl 1 (`OnClick: show page X`).
    const item = /^\s*menu\s+item\s+'([^']*)'.*?\b(?:show\s+)?page\s+([\w.]+)/i.exec(line);
    const [target, how] = home ? [home[1], home[2] ? `home page for ${home[2]}` : 'home page'] : item ? [item[2], `menu item '${item[1]}'`] : [];
    if (!target) continue;
    if (!opened.has(target)) opened.set(target, []);
    opened.get(target).push(how);
  }
  for (const queue = [...phone]; queue.length;) {
    for (const next of shows.get(queue.shift()) || []) if (!phone.has(next)) { phone.add(next); queue.push(next); }
  }
  // The pages those open with a button, and the pages those open: a browser user reaches them too.
  const queue = [...opened.keys()];
  while (queue.length) {
    const from = queue.shift();
    for (const next of shows.get(from) || []) {
      if (opened.has(next)) continue;
      opened.set(next, [`opened from ${from}`]);
      queue.push(next);
    }
  }
  const out = [];
  for (const [target, how] of opened) {
    const lay = layoutOf.get(target), kind = lay && kinds.get(lay);
    if (!kind || !/^(phone|tablet)$/i.test(kind)) continue;
    const head = `${target} opens in the browser profile Responsive (${how.join(', ')}), but its layout ${lay} is a ${kind} layout:` +
      ' in a browser the user gets the phone\'s bottom bar instead of the app\'s menu (My account, the other pages). ';
    const name = target.split('.').pop(), own = target.split('.')[0];
    out.push({ check: 'PHONE02', line: 0, message: head + (phone.has(target)
      ? `The phone and offline profiles open it too, and a page they open cannot move to Atlas_Default (mx check CE2994: its menu` +
        ` reaches pages that only work online). Give the browser its own copy: describe page ${target}, create it as` +
        ` ${own}.${name}_Web with Layout: Atlas_Core.Atlas_Default and its own Url, and point the Responsive profile's home page,` +
        ` menu item and the buttons of other _Web pages at it; the phone keeps ${target} (skill write-layouts)`
      : `Put it on a web layout: alter page ${target} { set layout = Atlas_Core.Atlas_Default }; and the same Layout: in the script` +
        ' that creates it (skill write-layouts)') });
  }
  return out;
}

// PHONE03 over the pages (DESCRIBE PAGE lines) and the describes of their layouts.
function phoneGridFindings(pageLines, layoutText) {
  const kinds = layoutKinds(layoutText);
  const out = [];
  let page = '', kind = '', grid = null;
  const flush = () => {
    if (!grid) return;
    const prefix = grid.name.split('_')[0], list = /Grid$/.test(grid.name) ? grid.name.replace(/Grid$/, 'List') : grid.name + 'List';
    const word = attr => attr.split('/').map(seg => seg.split('.').pop().split('_').pop()).join('');
    // An association path in a dynamic text needs its module (measured: RepairJob_Customer/Name -> Module.RepairJob_Customer/Name).
    const module = grid.page.split('.')[0];
    const path = attr => (attr.includes('/') && !attr.split('/')[0].includes('.') ? `${module}.${attr}` : attr);
    const texts = grid.columns.map((c, i) => `dynamictext ${prefix}_${word(c.attr)}Text (Content: '${i ? c.caption + ' ' : ''}{1}',` +
      ` ContentParams: ({1} = ${path(c.attr)}), RenderMode: ${i ? 'Paragraph' : 'H4'})`);
    out.push({ check: 'PHONE03', line: 0, message: `${grid.page} is on the ${grid.kind} layout and shows data grid ${grid.name}: on a phone its` +
      ` ${grid.columns.length + grid.buttons.length} columns cut the values short to a letter or two and "...". Show the items as a list view of cards,` +
      ` each value on its own line: alter page ${grid.page} { replace ${grid.name} with {` +
      (grid.header.length ? ` <${grid.header.join(', ')}, as they are, above the list>` : '') +
      ` listview ${list} (DataSource: <the grid's>) {` +
      ` container ${prefix}_ItemCardBox (DesignProperties: ('Spacing': ('padding': 'M'))) { ${texts.join(' ')}` +
      (grid.buttons.length ? ` container ${prefix}_ItemActionsBox { <${grid.buttons.join(', ')}, as they are> }` : '') +
      ' } } } }; and the same in the script that creates the page. The buttons keep their names, so row_action() still finds' +
      ' them (it reads any list); a column filter has no list view counterpart (skill spacing-and-layout)' });
    grid = null;
  };
  for (const line of pageLines) {
    const p = /^\s*create\s+(?:or\s+(?:replace|modify)\s+)?page\s+([\w.]+)/i.exec(line);
    if (p) { flush(); page = p[1]; kind = ''; continue; }
    const l = page && !kind && /^\s*layout\s*:\s*([\w.]+)/i.exec(line);
    if (l) { kind = kinds.get(l[1]) || '-'; continue; }
    if (!/^(phone|tablet)$/i.test(kind)) continue;
    const g = /^(\s*)datagrid\s+(\w+)/i.exec(line);
    if (g) { flush(); grid = { page, kind, name: g[2], indent: g[1].length, columns: [], buttons: [], header: [], bar: -1 }; continue; }
    if (!grid) continue;
    if (/^\s*}/.test(line) && line.search(/\S/) <= grid.indent) { flush(); continue; }
    // The grid's own header (controlbar): its buttons stay above the list, not in every card.
    if (/^\s*controlbar\b/i.test(line)) { grid.bar = line.search(/\S/); continue; }
    if (grid.bar >= 0 && /^\s*}/.test(line) && line.search(/\S/) <= grid.bar) { grid.bar = -1; continue; }
    const c = /^\s*column\b.*\bAttribute:\s*([\w./]+).*?\bCaption:\s*'([^']*)'/i.exec(line);
    if (c) { grid.columns.push({ attr: c[1], caption: c[2] }); continue; }
    const b = /^\s*(?:actionbutton|linkbutton)\s+(\w+)/i.exec(line);
    if (b) (grid.bar >= 0 ? grid.header : grid.buttons).push(b[1]);
  }
  flush();
  return out;
}

// PHONE04 over the pages, the describes of their layouts and the compiled theme
// (deployment/web/theme.compiled.css; '' when not built here: not judged).
const BROKEN_SCROLL = /\.mx-scrollcontainer-fixed\s+d\s+\.mx-scrollcontainer-middle/;
function phoneLayoutsUsed(pageLines, layoutText) {
  const kinds = layoutKinds(layoutText);
  const used = new Set();
  for (const line of pageLines) {
    const l = /^\s*layout\s*:\s*([\w.]+)/i.exec(line);
    if (l && /^(phone|tablet)$/i.test(kinds.get(l[1]) || '')) used.add(l[1]);
  }
  return used;
}

function stickyBarFindings(pageLines, layoutText, themeCss) {
  if (!BROKEN_SCROLL.test(themeCss || '')) return [];
  const used = phoneLayoutsUsed(pageLines, layoutText);
  if (!used.size) return [];
  const scss = 'themesource/atlas_core/web/core/widgets/_scroll-container-react.scss';
  return [{ check: 'PHONE04', line: 0, message: `the app's theme carries Atlas Core's broken selector` +
    ' ".mx-scrollcontainer-fixed d .mx-scrollcontainer-middle" (a stray "d"), so the content region of a layout never' +
    ` scrolls by itself: on a phone the whole page scrolls and the bottom bar of ${[...used].join(', ')} slides off the screen.` +
    ` Fix the one line in ${scss}: sed -i.bak 's/^\\( *\\)d \\.mx-scrollcontainer-middle {/\\1.mx-scrollcontainer-middle {/' ${scss}` +
    ' && rm ' + scss + '.bak -- the theme rebuilds by itself; the bar then stays on the screen and only the content scrolls.' +
    ' (Atlas Core 4.1.3, which the blank app of Mendix 11.12.1 ships, has the typo; 4.3.7 has it right: updating Atlas Core' +
    ' fixes it too, and is the person\'s call)' }];
}

// PHONE05 over the same inputs: the login form's fixed width, and no narrow-screen rule after it.
const FIXED_LOGIN = /\.loginpage-formwrapper\s*\{\s*width:\s*400px/;
const NARROW_LOGIN = /@media[^{]*max-width:\s*\d+px[^{]*\{\s*\.loginpage-formwrapper\s*\{[^}]*width:\s*(auto|100%|calc)/;
function loginWidthFindings(pageLines, layoutText, themeCss) {
  if (!FIXED_LOGIN.test(themeCss || '') || NARROW_LOGIN.test(themeCss || '')) return [];
  if (!phoneLayoutsUsed(pageLines, layoutText).size) return [];
  return [{ check: 'PHONE05', line: 0, message: 'the login page keeps Atlas Core\'s fixed ".loginpage-formwrapper { width: 400px }",' +
    ' so on a phone the form touches the left edge and runs off the right one. Add to the end of theme/web/main.scss (the' +
    ' app\'s own file; Atlas Core says not to edit its core): @media (max-width: 479px) { .loginpage-formwrapper { width: auto;' +
    ' margin: 0 var(--spacing-large, 24px); } } -- measured: 24 px each side at 390 and 320 px, 400 px on a desktop as before' }];
}

module.exports = { offlineProfiles, offlineFindings, testGoesOffline, layoutMenus, menuItems, phoneMenuFindings, webPhoneLayoutFindings, phoneGridFindings, stickyBarFindings, loginWidthFindings };
