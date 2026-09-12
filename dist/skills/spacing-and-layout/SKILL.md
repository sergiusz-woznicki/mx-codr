---
name: spacing-and-layout
description: "Spacing between widgets, using the theme's own Spacing design property rather than CSS — and the structure a screen is laid out with. Use before writing or altering any page or snippet, and when the gate's layout verdict fails."
---

# Spacing and layout

A screen can be correct and still look broken. Measured on this project: a gate
reported 10/10 tests, `mx check` 0 errors, lint 0 errors, coverage 12/12 and naming
clean, on a page whose heading, two buttons and grid were welded together with no gap
at all. Nothing in the model was wrong. The widgets simply carried no margin.

## The one thing to get right

**Two inline widgets next to each other need a margin on the first.** Inline means
buttons, link buttons, text, images, checkboxes — Atlas renders them on one line, so
without a margin they touch.

```
actionbutton btnRemind (
  Caption: 'Send reminder',
  Action: microflow Mod.ACT_Invoice_SendReminder(Invoice: $currentObject),
  DesignProperties: ['Spacing': ['margin-right': 'S']])
```

That is Studio Pro's own **Spacing** design property — the same dropdown a developer
would use. No `Class:`, no `Style:`, no custom CSS.

| | |
|---|---|
Sides | `margin-top` `margin-right` `margin-bottom` `margin-left`, and the same four as `padding-` |
Values | **`None` `S` `M` `L`** — Atlas Core defines nothing else |
Scopes | any widget, plus `LayoutGridRow` and `LayoutGridColumn` |
Side by side | `margin-right` |
Stacked | `margin-bottom` |

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
      actionbutton btnNew (Caption: 'New invoice', Action: ..., DesignProperties: ['Spacing': ['margin-right': 'S']])
      actionbutton btnReset (Caption: 'Reset demo data', Action: ...)
    }
  }
  row gridRow { column col1 (DesktopWidth: 12) { datagrid invoiceGrid (...) { ... } } }
}
```

The last widget in a group needs no margin — there is nothing after it to collide
with.

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
`SPACE01` | error | two inline widgets side by side and the first has no `margin-right`/`margin-bottom` |
`SPACE02` | error | a spacing value outside `None` `S` `M` `L` |
`HEAD01` | warning | the page renders no heading and calls no header snippet |

Nothing here judges colour, typography or contrast — those are not mechanically
checkable, and a rule that cannot be checked is advice. Look at the screen for those.
