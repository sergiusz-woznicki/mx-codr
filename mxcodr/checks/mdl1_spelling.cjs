// The MDL a finding suggests, in the spelling of the mxcli the harness is pinned to (0.25, `mdl 1`).
//
// The rules were written against mxcli 0.24 and build their fixes in its spelling: DesignProperties
// in [ ], `menu item 'X' page P icon I;`, `sign_out`, `close_page`, `grant Role on Entity (rights)
// where '...'`, `limit 1`. mxcli 0.25 still reads those in a script without a header, with a
// deprecation warning, and refuses them under `mdl 1;` -- the spelling its own `describe`, `syntax`
// and skills now use. So every checker's output passes through advice() before it is printed: one
// place that knows both spellings, rather than a second copy of every message. advice() changes
// syntax only, never a name, and leaves text with none of these spellings as it is.
'use strict';

// A [ ... ] group whose first member is a 'key': value pair (DesignProperties and the like), with
// its nested groups, becomes ( ... ). Brackets inside a quoted string are left alone.
function propertyBrackets(text) {
  let out = '';
  let i = 0;
  while (i < text.length) {
    if (text[i] === '[' && /^\['[^']*'\s*:/.test(text.slice(i))) {
      const end = matching(text, i);
      if (end > 0) {
        out += '(' + propertyBrackets(text.slice(i + 1, end)) + ')';
        i = end + 1;
        continue;
      }
    }
    out += text[i++];
  }
  return out;
}
// The index of the ] that closes the [ at `start`, skipping quoted strings; -1 when there is none.
function matching(text, start) {
  let depth = 0;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (c === "'") {
      i++;
      while (i < text.length && text[i] !== "'") i++;
      continue;
    }
    if (c === '[') depth++;
    else if (c === ']' && --depth === 0) return i;
  }
  return -1;
}

const RULES = [
  // Text template parameters: CaptionParams: [{1} = X] -> ({1} = X).
  [/\b(CaptionParams|ContentParams):\s*\[([^\]]*)\]/g, '$1: ($2)'],
  // Menu items: properties in ( ), the action is OnClick.
  [/menu item ('[^']*') sign_out icon ([^;`\n]+);/g, 'menu item $1 ( OnClick: sign out, Icon: $2 )'],
  [/menu item ('[^']*') page ([^\s;`]+) icon ([^;`\n]+);/g, 'menu item $1 ( OnClick: show page $2, Icon: $3 )'],
  [/menu item ('[^']*') microflow ([^\s;`]+) icon ([^;`\n]+);/g, 'menu item $1 ( OnClick: call microflow $2, Icon: $3 )'],
  [/`icon (Atlas_[^`\s]+)`/g, '`Icon: $1`'],
  [/\bcreate or replace navigation\b/g, 'create or modify navigation'],
  [/\bsign_out\b/g, 'sign out'],
  // Button actions.
  [/\bSAVE_CHANGES\b/g, 'save changes'],
  [/\bCANCEL_CHANGES\b/g, 'cancel changes'],
  [/\b(?:CLOSE_PAGE|close_page)\b/g, 'close page'],
  [/\bshow_page\b/g, 'show page'],
  [/\bAction:\s*microflow\b/g, 'Action: call microflow'],
  // A control bar has no name in Mendix.
  [/\bcontrolbar [A-Za-z_]\w* \{/g, 'controlbar {'],
  // One object from a retrieve.
  [/\blimit 1;/g, 'first;'],
  [/`limit 1`/g, '`first`'],
  // Entity access: rights first, the entity and the role named, the XPath in [ ] with plain quotes.
  [/\bgrant ([\w.<>{}$]+) on ([\w."<>{}$]+) \(([^()]*(?:\([^()]*\)[^()]*)*)\) where '((?:[^']|'')*)'/g,
    (all, role, entity, rights, xpath) => `grant ${rights} on entity ${entity} to ${role} where ${xpath.replace(/''/g, "'")}`],
  [/\bgrant ([\w.<>{}$]+) on ([\w."<>{}$]+) \(([^()]*(?:\([^()]*\)[^()]*)*)\)/g,
    (all, role, entity, rights) => `grant ${rights} on entity ${entity} to ${role}`],
  [/\brevoke ([\w.<>{}$]+) on ([\w."<>{}$]+);/g, 'revoke all on entity $2 from $1;'],
];

function advice(text) {
  let out = propertyBrackets(text);
  for (const [pattern, replacement] of RULES) out = out.replace(pattern, replacement);
  return out;
}

module.exports = { advice, propertyBrackets };
