#!/usr/bin/env python3
"""Check that screens are laid out with the theme's own spacing.

A page can pass every other verdict and still look broken. Measured: a gate that
reported 10/10 tests, `mx check` 0 errors, lint 0 errors, coverage 12/12 and naming
clean, on a page whose heading, two buttons and grid were welded together with no
gap at all -- because the widgets were emitted as bare siblings:

    column col1 (DesktopWidth: 12) {
      dynamictext heading (Content: 'Chase overdue invoices', RenderMode: H2)
      actionbutton btnRefresh (Caption: 'Refresh statuses', ...)   <-- touching
      datagrid ChaseGrid (...)
    }

Mendix has a property for this and it needs no CSS. Atlas Core declares a `Spacing`
design property on the `Widget`, `LayoutGridRow` and `LayoutGridColumn` scopes, with
`margin-` and `padding-` on each of the four sides. In MDL:

    actionbutton btnRemind (
      Caption: 'Send reminder',
      Action: microflow Mod.ACT_Remind(Invoice: $currentObject),
      DesignProperties: ['Spacing': ['margin-right': 'S', 'margin-bottom': 'S']])

Two errors and one warning, all read out of `describe page` -- which prints
`DesignProperties`, where mxcli's Starlark rules cannot help: a `page` object there
exposes only `widget_count`.

    SPACE01  error    two inline widgets side by side, neither carrying a margin
    SPACE02  error    a spacing value Atlas does not define (it offers None, S, M, L)
    HEAD01   warning  the page renders no heading widget

SPACE02 exists because `mxcli check` accepts any value here -- `'XL'` passes -- and
only `mx check` catches it, late, as CE6083 "Design property Spacing is not
supported by your theme".

    python3 check_layout.py <dir-of-describe-dumps>|<file.mdl> [--json]

Exit 0 when no error survives; warnings never fail the run.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Atlas Core's own vocabulary, read from
# themesource/atlas_core/web/design-properties.json: the Spacing property offers
# exactly these four on every side, for both margin and padding.
SPACING_VALUES = {"None", "S", "M", "L"}

# Structural widgets: a grid row, a grid column and a layout region carry the
# spacing of the thing they lay out, and a datagrid's columns are table cells --
# asking any of them for a margin of its own is wrong, not merely unnecessary.
STRUCTURAL = {"row", "column", "region", "placeholder", "controlbar", "header", "footer"}

# Only these collide. Atlas renders them on one line, so two in a row touch unless
# one carries a margin -- which is exactly the defect this file exists for. Everything
# else (a textbox, a datagrid, a layoutgrid, a snippetcall, a dataview) is block-level
# and already spaced by the theme's form and container styles; flagging those produced
# 20 findings on an app whose screens look right, so they are not flagged.
INLINE = {"actionbutton", "linkbutton", "dynamictext", "text", "image", "staticimage",
          "dynamicimage", "checkbox", "radiobuttons"}

WIDGET_RE = re.compile(r"^(?P<indent>\s*)(?P<type>[a-z][a-z0-9_]*)\s+(?P<name>\"[^\"]+\"|[A-Za-z_][\w/]*)\s*[({]")
# A widget can also be written without a name (rare, and mxcli prints one anyway),
# or as `type (` -- caught here so it still counts as a sibling.
ANON_RE = re.compile(r"^(?P<indent>\s*)(?P<type>[a-z][a-z0-9_]*)\s*[({]")
PAGE_RE = re.compile(r"^create (?:or (?:replace|modify) )?page\s+(?P<name>[\w.\"]+)", re.IGNORECASE)
SPACING_RE = re.compile(r"'Spacing'\s*:\s*\[(?P<body>[^\]]*)\]")
PAIR_RE = re.compile(r"'(?P<key>margin|padding)-(?P<side>top|right|bottom|left)'\s*:\s*'(?P<value>[^']*)'")


class Widget:
    __slots__ = ("type", "name", "line", "indent", "text", "page")

    def __init__(self, wtype: str, name: str, line: int, indent: int, page: str):
        self.type = wtype
        self.name = name.strip('"')
        self.line = line
        self.indent = indent
        self.text = ""
        self.page = page


def parse(lines: list[str]) -> list[Widget]:
    """Every widget in the dump, each carrying its own property text.

    Indentation is the structure: `describe` emits two spaces per level, a widget's
    properties deeper than the widget, and a nested widget deeper again. A line that
    opens a widget is `type name (` or `type name {`; anything else is a property,
    a closing brace, or a comment.
    """
    widgets: list[Widget] = []
    page = ""
    open_widget: Widget | None = None
    for number, raw in enumerate(lines, 1):
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("--"):
            continue
        page_match = PAGE_RE.match(line.strip())
        if page_match:
            page = page_match.group("name").replace('"', "")
            open_widget = None
            continue
        match = WIDGET_RE.match(line) or ANON_RE.match(line)
        if match and match.group("type") not in ("create", "grant", "layouttype", "class"):
            widget = Widget(match.group("type"), match.groupdict().get("name") or "", number,
                            len(match.group("indent")), page)
            widget.text = line.strip()
            widgets.append(widget)
            open_widget = widget
            continue
        # A property line belongs to the widget it is indented under -- that is where
        # a multi-line DesignProperties block lives.
        if open_widget is not None and len(line) - len(line.lstrip()) > open_widget.indent:
            open_widget.text += " " + line.strip()
    return widgets


def siblings(widgets: list[Widget]) -> dict[tuple[str, int, int], list[Widget]]:
    """Group widgets by parent: same page, same indentation, no shallower widget between."""
    groups: dict[tuple[str, int, int], list[Widget]] = {}
    for index, widget in enumerate(widgets):
        # The parent is the nearest preceding widget with less indentation.
        parent_line = 0
        for earlier in reversed(widgets[:index]):
            if earlier.page == widget.page and earlier.indent < widget.indent:
                parent_line = earlier.line
                break
        groups.setdefault((widget.page, parent_line, widget.indent), []).append(widget)
    return groups


def spacing_of(widget: Widget) -> dict[str, str]:
    found = SPACING_RE.search(widget.text)
    if not found:
        return {}
    return {f"{m.group('key')}-{m.group('side')}": m.group("value")
            for m in PAIR_RE.finditer(found.group("body"))}


def check(lines: list[str]) -> tuple[list[dict], list[dict], int]:
    widgets = parse(lines)
    failures: list[dict] = []
    warnings: list[dict] = []

    for widget in widgets:
        for key, value in spacing_of(widget).items():
            if value not in SPACING_VALUES:
                failures.append({
                    "check": "SPACE02",
                    "line": widget.line,
                    "message": (f"{widget.page}: {widget.type} '{widget.name}' sets {key}: '{value}',"
                                f" which Atlas does not define -- use one of"
                                f" {', '.join(sorted(SPACING_VALUES))}"),
                })

    for (page, _parent, _indent), group in siblings(widgets).items():
        if len(group) < 2:
            continue
        # The last one has nothing after it to collide with.
        for index, widget in enumerate(group[:-1]):
            following = group[index + 1]
            if widget.type in STRUCTURAL or following.type in STRUCTURAL:
                continue
            # Both sides have to be inline for them to end up on one line together.
            if widget.type not in INLINE or following.type not in INLINE:
                continue
            spacing = spacing_of(widget)
            if any(spacing.get(side) not in (None, "None")
                   for side in ("margin-right", "margin-bottom")):
                continue
            failures.append({
                "check": "SPACE01",
                "line": widget.line,
                "message": (f"{page}: {widget.type} '{widget.name}' sits directly against"
                            f" {following.type} '{following.name}' with no margin --"
                            f" add DesignProperties: ['Spacing': ['margin-right': 'S']]"
                            f" (side by side) or ['margin-bottom': 'S'] (stacked)"),
            })

    # Per page, from the parsed widgets -- not from slicing the text on "page <name>",
    # which also matches the `grant view on page <name>` line printed after the body
    # and so reported every page as heading-less, including ones with an H2.
    headed: dict[str, bool] = {}
    for widget in widgets:
        if not widget.page:
            continue
        headed.setdefault(widget.page, False)
        # Three conventions all count as headed, because all three put a title on
        # the screen: an H1-H3 in the page, a `header` region, or a shared snippet
        # that carries the heading -- InvoiceDesk uses SNIPPET_AppHeader with an H1
        # inside, which is the reuse-first way and must not be reported as missing.
        if (
            widget.type == "header"
            or (widget.type in ("dynamictext", "text")
                and re.search(r"RenderMode:\s*(H1|H2|H3)", widget.text))
            or (widget.type == "snippetcall"
                and re.search(r"Snippet:\s*[\w.]*(header|title|masthead)", widget.text, re.I))
        ):
            headed[widget.page] = True
    pages = set(headed)
    for page in sorted(pages):
        if not headed[page]:
            warnings.append({
                "check": "HEAD01",
                "line": 0,
                "message": (f"{page} renders no heading widget. Stock Atlas layouts show the app"
                            f" brand, not the page title, so a page with no heading opens"
                            f" unlabelled -- unless this app puts headings in a shared snippet"),
            })
    return failures, warnings, len(pages)


def collect(sources: list[Path]) -> tuple[str, list[Path]]:
    chunks, used = [], []
    for source in sources:
        files = sorted(source.rglob("*.mdl")) if source.is_dir() else ([source] if source.exists() else [])
        for file in files:
            chunks.append(file.read_text(encoding="utf-8", errors="replace"))
            used.append(file)
    return "\n".join(chunks), used


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="+", type=Path, help="describe-page dumps, or a directory of them")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    text, used = collect(args.sources)
    if not text.strip():
        print(f"FAIL  no MDL found in {[str(s) for s in args.sources]}", file=sys.stderr)
        return 1

    failures, warnings, pages = check(text.splitlines())
    report = {
        "verdict": "PASS" if not failures else "FAIL",
        "pages": pages,
        "sources": [str(p) for p in used],
        "failures": failures,
        "warnings": warnings,
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"{report['verdict']}  {len(failures)} failure(s) over {pages} page(s)")
        for failure in failures:
            print(f"  - [{failure['check']}] line {failure['line']}: {failure['message']}")
        for warning in warnings:
            print(f"  ! [{warning['check']}] {warning['message']}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
