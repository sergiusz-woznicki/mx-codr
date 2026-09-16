---
name: spacing-and-layout
description: "Spacing between widgets, using the theme's own Spacing design property rather than CSS — and the structure a screen is laid out with, including the main menu (a Log out item once users can sign in). Use before writing or altering any page, snippet or navigation menu, and when the gate's layout verdict fails."
---

# Spacing and layout

A screen can be correct and still look broken. Measured on this project: a gate
reported 10/10 tests, `mx check` 0 errors, lint 0 errors, coverage 12/12 and naming
clean, on a page whose heading, two buttons and grid were welded together with no gap
at all. Nothing in the model was wrong. The widgets simply carried no margin.

## The one thing to get right

**Widgets that share a line need `margin-right` between them and the same
`margin-bottom` on all of them.** Inline means buttons, link buttons, paragraph text,
images, checkboxes — Atlas puts them on one line, and that line *wraps* when the
window narrows.

```
actionbutton btnEdit   (Caption: 'Edit',   Action: ..., DesignProperties: ['Spacing': ['margin-right': 'S', 'margin-bottom': 'S']])
actionbutton btnDelete (Caption: 'Delete', Action: ..., DesignProperties: ['Spacing': ['margin-right': 'S', 'margin-bottom': 'S']])
actionbutton btnSend   (Caption: 'Send',   Action: ..., DesignProperties: ['Spacing': ['margin-bottom': 'S']])
```

Three measured failures, each from leaving part of that out:

| What was written | What it looked like |
|---|---|
| `margin-right` on the first only | the second button touching the first |
| `margin-right` on one, `margin-bottom` on its neighbour | the two ten pixels out of line — a bottom margin lifts an inline-block off the baseline |
| `margin-right` on both, `margin-bottom` on neither | right on a wide screen; narrow the window and three buttons wrap onto two rows, the second against the first |

So the gap goes on every widget but the last, and the bottom margin goes on **all** of
them, with the same value.

That is Studio Pro's own **Spacing** design property — the same dropdown a developer
would use. No `Class:`, no `Style:`, no custom CSS.

| | |
|---|---|
Sides | `margin-top` `margin-right` `margin-bottom` `margin-left`, and the same four as `padding-` |
Values | **`None` `S` `M` `L`** — Atlas Core defines nothing else |
Scopes | any widget, plus `LayoutGridRow` and `LayoutGridColumn` |
Side by side | `margin-right` on each but the last |
Stacked, or a line that can wrap | `margin-bottom` on every one, same value |

`mxcli check` does **not** validate the value: `'XL'` passes it and then fails much
later in `mx check` as CE6083 *"Design property Spacing is not supported by your
theme"*. The gate's `layout` verdict catches it immediately instead.

## What does not need a margin

Block-level widgets already carry the theme's spacing, and adding margins to them
makes the screen worse, not better:

- `textbox`, `datepicker`, `combobox`, `checkbox` inside a `dataview` — Atlas form
  groups are spaced,
- `datagrid`, `listview`, `gallery`, `layoutgrid`, `container`, `snippetcall`,
- a grid `row`, a grid `column`, a datagrid `column`, a layout `region`, a `footer`
  or `header` — these lay other things out and have their own spacing.

The gate only fails on inline-against-inline for this reason.

## Structure

Widgets belong inside a `layoutgrid` / `row` / `column`, not loose in a container:
the grid is what makes a screen responsive, and column widths are how two things sit
side by side on a desktop and stack on a phone.

```
layoutgrid pageGrid {
  row headerRow {
    column colTitle  (DesktopWidth: 8) { dynamictext heading (Content: 'Invoices', RenderMode: H2) }
    column colActions (DesktopWidth: 4) {
      actionbutton btnNew   (Caption: 'New invoice',     Action: ..., DesignProperties: ['Spacing': ['margin-right': 'S', 'margin-bottom': 'S']])
      actionbutton btnReset (Caption: 'Reset demo data', Action: ..., DesignProperties: ['Spacing': ['margin-bottom': 'S']])
    }
  }
  row gridRow { column col1 (DesktopWidth: 12) { datagrid invoiceGrid (...) { ... } } }
}
```

The last widget in a line needs no `margin-right` — nothing follows it — but it keeps
the same `margin-bottom` as the rest, or a wrapped row lands against the one above.

## The main menu: Log out once users can sign in

The navigation menu frames every screen. As soon as the app has user accounts that
sign in (customer logins, demo users, an Administration account page), its main menu
ends with a **Log out** item, in every navigation profile those users reach. Without
it a user can only end the session by closing the browser.

```sql
create or replace navigation Responsive
  home page MyFirstModule.Home_Web
  menu (
    menu item 'Invoices' page Invoicing.Invoice_Overview icon Atlas_Core.Atlas_Filled.document;
    menu item 'Log out' sign_out icon Atlas_Core.Atlas_Filled.logout;
  )
;
```

`sign_out` needs no page or microflow, and it is always the **last** item.
`create or replace navigation` replaces the whole menu: `DESCRIBE NAVIGATION Responsive`
first and keep the items already there.

The gate's layout verdict fails (`NAV01`) while security is on and no menu, page or
snippet offers a way to log out.

## Headings

Stock Atlas layouts render the **app** brand in the top region, not the page title,
and the page's `Title:` property feeds the browser tab and the menu — not the screen.
So a page with no heading widget opens unlabelled. Two conventions both work, and the
gate accepts either:

- an `H1`–`H3` `dynamictext` in the page, or
- one shared snippet every page calls — `SNIPPET_AppHeader` in the demo app, which is
  what [reuse-and-snippets](../reuse-and-snippets/SKILL.md) would have you do.

Pick one per app and keep to it. This is a warning in the gate, never a failure: it
is a convention, and a rule must only fail things that are wrong under every
convention.

## Fixing an existing page

`ALTER PAGE`'s `SET` cannot take a `DesignProperties` map — it rejects the value.
Patch the page body instead, which is re-runnable:

```bash
./mxcli describe PAGE Mod.Invoice_Overview -p app.mpr > /tmp/page.mdl
# add DesignProperties to the offending widget
./mxcli check /tmp/page.mdl -p app.mpr --references && ./mxcli exec /tmp/page.mdl -p app.mpr
```

## Check it

```bash
bash tests/gate.sh            # the layout verdict, with the rest
```

```
layout: PASS  0 failure(s) over 6 page(s)
```

| Check | Severity | Fails when |
|---|---|---|
`SPACE01` | error | a widget sharing a line with the next and no `margin-right`; or a heading with content under it and no `margin-bottom` |
`SPACE02` | error | a spacing value outside `None` `S` `M` `L` |
`SPACE03` | error | widgets on one line disagreeing on vertical margins (misaligned), or none carrying `margin-bottom` (wraps into the row above) |
`HEAD01` | warning | the page renders no heading and calls no header snippet |
`NAV01` | error | project security is on, a navigation menu has no `sign_out` item, and no page or snippet has a sign-out button |
`NAV02` | warning | the `sign_out` item is not the last item of its menu |

## What this cannot see

A narrow window also **cuts content off sideways** when a grid has more columns than
fit. No margin fixes that and no read of the MDL proves it: it is a datagrid with too
many columns for a phone, or a `layoutgrid` column that never stacks. Judge that by
narrowing the browser.

Nothing here judges colour, typography or contrast — those are not mechanically
checkable, and a rule that cannot be checked is advice. Look at the screen for those.
