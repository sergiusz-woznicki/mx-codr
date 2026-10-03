"""GRID02: a button that changes the rows a data grid shows sits in that grid's own header.

Data Grid 2 has a header above its rows -- `controlbar` in MDL, where the grid-wide filters go.
A New, Delete-selected or Mark-paid button belongs there, with the rows it changes, not in a
container above or beside the grid.

Part of check_layout.py; see its docstring for inputs and the full rule table.
"""

from __future__ import annotations

import re

from .pages import parse

# The grid's entity: `DataSource: database from Mod.Entity` or `DataSource: microflow Mod.DS_x(...)`.
DB_SOURCE_RE = re.compile(r"\bDataSource:\s*database\s+(?:from\s+)?(?P<entity>[A-Za-z_]\w*\.[A-Za-z_]\w*)", re.IGNORECASE)
FLOW_SOURCE_RE = re.compile(r"\bDataSource:\s*(?:microflow|nanoflow)\s+(?P<flow>[A-Za-z_]\w*\.[A-Za-z_]\w*)", re.IGNORECASE)
ACTION_RE = re.compile(r"\bAction:\s*(?P<action>.+)", re.IGNORECASE)
CREATE_OBJECT_RE = re.compile(r"^create_object\s+(?P<entity>[A-Za-z_]\w*\.[A-Za-z_]\w*)", re.IGNORECASE)
CALL_RE = re.compile(r"^(?:microflow|nanoflow)\s+(?P<flow>[A-Za-z_]\w*\.[A-Za-z_]\w*)", re.IGNORECASE)
BUTTONS = {"actionbutton", "linkbutton", "container"}

# Flow dumps: one `create [or modify] microflow|nanoflow Mod.Name` per flow.
FLOW_HEAD_RE = re.compile(r"^\s*create\s+(?:or\s+(?:replace|modify)\s+)?(?:microflow|nanoflow)\s+(?P<name>[\w.]+)",
                          re.IGNORECASE | re.MULTILINE)
RETURNS_RE = re.compile(r"^\s*returns\s+list\s+of\s+(?P<entity>[\w.]+)", re.IGNORECASE | re.MULTILINE)
CALLS_RE = re.compile(r"\bcall\s+(?:microflow|nanoflow)\s+(?P<flow>[A-Za-z_]\w*\.[A-Za-z_]\w*)", re.IGNORECASE)
WRITE_RE = re.compile(r"\b(?:change|commit|delete)\s+\$(?P<var>\w+)", re.IGNORECASE)


def flow_bodies(flows: str) -> dict[str, str]:
    heads = list(FLOW_HEAD_RE.finditer(flows))
    return {h.group("name"): flows[h.start():(heads[i + 1].start() if i + 1 < len(heads) else len(flows))]
            for i, h in enumerate(heads)}


def _typed(body: str, entity: str) -> set[str]:
    """Variables of the entity (or a list of it) in one flow: parameters, retrieves, creates, loops."""
    e = re.escape(entity)
    found = set(re.findall(r"\$(\w+)\s*:\s*(?:list\s+of\s+)?" + e + r"\b", body, re.IGNORECASE))
    found |= set(re.findall(r"\bretrieve\s+\$(\w+)\s+from\s+(?:database\s+)?" + e + r"\b", body, re.IGNORECASE))
    found |= set(re.findall(r"\$(\w+)\s*=\s*create\s+(?:list\s+of\s+)?" + e + r"\b", body, re.IGNORECASE))
    for item, source in re.findall(r"\bloop\s+\$(\w+)\s+in\s+\$(\w+)", body, re.IGNORECASE):
        if source in found:
            found.add(item)
    return found


def writes(flow: str, entity: str, bodies: dict[str, str], depth: int = 0, seen: set | None = None) -> bool:
    """Does the flow, or a flow it calls (three deep), create, change, commit or delete the entity?"""
    seen = seen if seen is not None else set()
    body = bodies.get(flow)
    if body is None or flow in seen or depth > 3:
        return False
    seen.add(flow)
    if re.search(r"\bcreate\s+(?:list\s+of\s+)?" + re.escape(entity) + r"\b", body, re.IGNORECASE):
        return True
    typed = _typed(body, entity)
    if any(m.group("var") in typed for m in WRITE_RE.finditer(body)):
        return True
    return any(writes(m.group("flow"), entity, bodies, depth + 1, seen) for m in CALLS_RE.finditer(body))


def header_button_findings(lines: list[str], flows: str) -> list[dict]:
    """GRID02: buttons outside a data grid that change the rows it shows."""
    bodies = flow_bodies(flows)
    widgets = parse(lines)
    failures = []
    pages: dict[str, list] = {}
    for widget in widgets:
        pages.setdefault(widget.page, []).append(widget)
    for page, items in pages.items():
        grids = []   # (grid widget, entity, index range of its subtree)
        for i, widget in enumerate(items):
            if widget.type != "datagrid":
                continue
            entity = ""
            db = DB_SOURCE_RE.search(widget.text)
            if db:
                entity = db.group("entity")
            else:
                source = FLOW_SOURCE_RE.search(widget.text)
                returned = source and RETURNS_RE.search(bodies.get(source.group("flow"), ""))
                entity = returned.group("entity") if returned else ""
            end = i + 1
            while end < len(items) and items[end].indent > widget.indent:
                end += 1
            grids.append((widget, entity, range(i, end)))
        if not grids:
            continue
        for i, widget in enumerate(items):
            if widget.type not in BUTTONS or any(i in inside for _, _, inside in grids):
                continue
            found = ACTION_RE.search(widget.text)
            if not found:
                continue
            action = found.group("action").strip()
            for grid, entity, _ in grids:
                why = ""
                created = CREATE_OBJECT_RE.match(action)
                called = CALL_RE.match(action)
                if re.search(r"\$" + re.escape(grid.name) + r"\b", action):
                    why = f"it acts on {grid.name}'s selection"
                elif entity and created and created.group("entity").lower() == entity.lower():
                    why = f"it creates {entity} objects, the rows of {grid.name}"
                elif entity and called and writes(called.group("flow"), entity, bodies):
                    why = f"{called.group('flow')} changes {entity}, the rows of {grid.name}"
                if not why:
                    continue
                failures.append({
                    "check": "GRID02",
                    "line": widget.line,
                    "message": (f"{page}: {widget.type} {widget.name} sits outside data grid {grid.name}, but {why}"
                                f" -- move it into the grid's header: `controlbar ctb{grid.name[2:] if grid.name.startswith('dg') else grid.name} {{ ... }}`"
                                f" inside `datagrid {grid.name} {{ }}`, after the columns. The header is not row-scoped:"
                                f" pass the grid's selection as `${grid.name}` or a page parameter; `$currentObject`"
                                f" and an enclosing data view's name do not resolve there (CE0117)"),
                })
                break
    return failures
