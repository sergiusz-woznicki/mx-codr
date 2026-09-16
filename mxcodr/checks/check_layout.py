#!/usr/bin/env python3
"""Check that page widgets are spaced with Atlas Spacing design properties.

Input: `describe page` dumps (.mdl files or directories), normally from tests/gate.sh.
Usage: check_layout.py <file.mdl|dir> ... [--json]
--json keys: verdict, pages, sources, failures, warnings.
Exit: 0 no errors (warnings allowed), 1 errors or no MDL found, 2 bad arguments.
"""

# Rule codes:
#   SPACE01  FAIL  inline sibling (not last) without margin-right, or H1-H3 heading with a sibling below and no margin-bottom
#   SPACE02  FAIL  margin/padding value other than None, S, M, L (mxcli check accepts it; mx check fails with CE6083)
#   SPACE03  FAIL  inline widgets on one line with different top/bottom margins, or none with margin-bottom
#   HEAD01   WARN  page with no H1-H3 text, no header widget and no header/title/masthead snippet

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Spacing values Atlas Core's design-properties.json defines.
SPACING_VALUES = {"None", "S", "M", "L"}

# Layout containers never take a margin of their own.
STRUCTURAL = {"row", "column", "region", "placeholder", "controlbar", "header", "footer"}

# Rendered on one line, so they touch unless spaced; block-level widgets are spaced by the theme.
INLINE = {"actionbutton", "linkbutton", "dynamictext", "text", "image", "staticimage",
          "dynamicimage", "checkbox", "radiobuttons"}

# A heading renders as a block, so it never joins a line run; it only needs margin-bottom.
HEADING_MODE = re.compile(r"RenderMode:\s*(H1|H2|H3)", re.IGNORECASE)


def is_heading(widget) -> bool:
    return widget.type in ("dynamictext", "text") and bool(HEADING_MODE.search(widget.text))


def runs_of(group: list) -> list[list]:
    """Split siblings into the runs of inline widgets that share one line."""
    runs, current = [], []
    for widget in group:
        if widget.type not in INLINE or widget.type in STRUCTURAL or is_heading(widget):
            if current:
                runs.append(current)
            current = []
            continue
        current.append(widget)
    if current:
        runs.append(current)
    return runs

# `<indent><type> <name> (` or `{`; name may be "double-quoted".
WIDGET_RE = re.compile(r"^(?P<indent>\s*)(?P<type>[a-z][a-z0-9_]*)\s+(?P<name>\"[^\"]+\"|[A-Za-z_][\w/]*)\s*[({]")
# Unnamed widget: `<type> (` or `{`.
ANON_RE = re.compile(r"^(?P<indent>\s*)(?P<type>[a-z][a-z0-9_]*)\s*[({]")
PAGE_RE = re.compile(r"^create (?:or (?:replace|modify) )?page\s+(?P<name>[\w.\"]+)", re.IGNORECASE)
# Group "body": the inside of `'Spacing': [ ... ]`.
SPACING_RE = re.compile(r"'Spacing'\s*:\s*\[(?P<body>[^\]]*)\]")
# One `'margin-right': 'S'` pair.
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
    """Widgets in the dump with their property text; indentation gives the nesting."""
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
        # Deeper lines (e.g. multi-line DesignProperties) belong to the open widget.
        if open_widget is not None and len(line) - len(line.lstrip()) > open_widget.indent:
            open_widget.text += " " + line.strip()
    return widgets


def siblings(widgets: list[Widget]) -> dict[tuple[str, int, int], list[Widget]]:
    """Group widgets by (page, parent line, indent)."""
    groups: dict[tuple[str, int, int], list[Widget]] = {}
    for index, widget in enumerate(widgets):
        parent_line = 0
        for earlier in reversed(widgets[:index]):
            if earlier.page == widget.page and earlier.indent < widget.indent:
                parent_line = earlier.line
                break
        groups.setdefault((widget.page, parent_line, widget.indent), []).append(widget)
    return groups


def spacing_of(widget: Widget) -> dict[str, str]:
    """Spacing as {"margin-right": "S", ...}; unset sides are absent."""
    found = SPACING_RE.search(widget.text)
    if not found:
        return {}
    return {f"{m.group('key')}-{m.group('side')}": m.group("value")
            for m in PAIR_RE.finditer(found.group("body"))}


def invalid_value_findings(widgets: list[Widget]) -> list[dict]:
    """SPACE02: a spacing value Atlas does not define."""
    failures = []
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
    return failures


def heading_findings(page: str, group: list[Widget]) -> list[dict]:
    """SPACE01: heading with a sibling below."""
    failures = []
    for index, widget in enumerate(group[:-1]):
        if not is_heading(widget):
            continue
        if spacing_of(widget).get("margin-bottom", "None") != "None":
            continue
        failures.append({
            "check": "SPACE01",
            "line": widget.line,
            "message": (f"{page}: heading '{widget.name}' has nothing under it but"
                        f" {group[index + 1].type} '{group[index + 1].name}' --"
                        f" add DesignProperties: ['Spacing': ['margin-bottom': 'S']]"),
        })
    return failures


def run_gap_findings(page: str, run: list[Widget]) -> list[dict]:
    """SPACE01: the last widget in a run has nothing to collide with."""
    failures = []
    for widget in run[:-1]:
        if spacing_of(widget).get("margin-right", "None") != "None":
            continue
        following = run[run.index(widget) + 1]
        failures.append({
            "check": "SPACE01",
            "line": widget.line,
            "message": (f"{page}: {widget.type} '{widget.name}' sits on one line with"
                        f" {following.type} '{following.name}' and no gap between them"
                        f" -- add DesignProperties: ['Spacing': ['margin-right': 'S']]"),
        })
    return failures


def run_alignment_findings(page: str, run: list[Widget]) -> list[dict]:
    """SPACE03: unequal vertical margins misalign the run; no margin-bottom makes wrapped rows touch."""
    vertical = {w.name: (spacing_of(w).get("margin-top", "None"),
                         spacing_of(w).get("margin-bottom", "None")) for w in run}
    shown = ", ".join(f"{name} {top}/{bottom}" for name, (top, bottom) in vertical.items())
    names = " and ".join(w.name for w in run)
    if len(set(vertical.values())) > 1:
        return [{
            "check": "SPACE03",
            "line": run[0].line,
            "message": (f"{page}: {names} sit on one line with"
                        f" different vertical spacing, so they render at different heights"
                        f" (margin-top/bottom: {shown}). Make those equal, and use"
                        f" margin-right for the gap between them"),
        }]
    if all(bottom == "None" for _top, bottom in vertical.values()):
        return [{
            "check": "SPACE03",
            "line": run[0].line,
            "message": (f"{page}: {names} share a line and none"
                        f" carries margin-bottom, so on a narrow window the line wraps and"
                        f" the second row sits against the first -- add"
                        f" ['margin-right': 'S', 'margin-bottom': 'S'] to each"
                        f" (the last one needs the bottom margin only)"),
        }]
    return []


def headed_pages(widgets: list[Widget]) -> dict[str, bool]:
    """{page: has a heading}; parsed widgets, since text "page <name>" also matches `grant view on page`."""
    headed: dict[str, bool] = {}
    for widget in widgets:
        if not widget.page:
            continue
        headed.setdefault(widget.page, False)
        # A shared header snippet counts as a heading.
        if (
            widget.type == "header"
            or (widget.type in ("dynamictext", "text")
                and re.search(r"RenderMode:\s*(H1|H2|H3)", widget.text))
            or (widget.type == "snippetcall"
                and re.search(r"Snippet:\s*[\w.]*(header|title|masthead)", widget.text, re.I))
        ):
            headed[widget.page] = True
    return headed


def missing_heading_warnings(headed: dict[str, bool]) -> list[dict]:
    """HEAD01: a page with no heading."""
    warnings = []
    for page in sorted(headed):
        if not headed[page]:
            warnings.append({
                "check": "HEAD01",
                "line": 0,
                "message": (f"{page} renders no heading widget. Stock Atlas layouts show the app"
                            f" brand, not the page title, so a page with no heading opens"
                            f" unlabelled -- unless this app puts headings in a shared snippet"),
            })
    return warnings


def check(lines: list[str]) -> tuple[list[dict], list[dict], int]:
    """Return (failures, warnings, page count)."""
    widgets = parse(lines)
    failures = invalid_value_findings(widgets)

    for (page, _parent, _indent), group in siblings(widgets).items():
        if len(group) < 2:
            continue
        failures.extend(heading_findings(page, group))
        for run in runs_of(group):
            if len(run) < 2:
                continue
            failures.extend(run_gap_findings(page, run))
            failures.extend(run_alignment_findings(page, run))

    headed = headed_pages(widgets)
    return failures, missing_heading_warnings(headed), len(headed)


def collect(sources: list[Path]) -> tuple[str, list[Path]]:
    """Joined text of every .mdl under sources, and the files read."""
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
