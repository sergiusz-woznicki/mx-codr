"""PERF07: an attribute the app filters or sorts on, with no database index that starts with it.

    from index_rules import index_findings
    index_findings(entity_lines, document_lines) -> [(code, message, line)]

<entity_lines> is DESCRIBE ENTITY output for the project's own entities; <document_lines> is
DESCRIBE output for its microflows, nanoflows and pages. An attribute counts as used when a
retrieve or a page's database source compares it in its XPath (`=`, `<`, `>`, `<=`, `>=`) or
sorts by it. Mendix indexes `id`, every association and every attribute with a uniqueness rule
by itself (measured on PostgreSQL, 2026-10-04); everything else is a full table scan. Measured
the same day on a copy of InvoiceB2B's orders at 200,000 rows: the latest order by date 35 ms
without an index and 0.01 ms with one; one status 9.7 ms and 2.0 ms. At 10,000 rows both are
under 2 ms, so this is a warning. Not reported: booleans (two values, the database scans
anyway), `!=` and `contains()` (an index does not help them), view and non-persistent
entities (no table of their own), attributes already first in an index, and seed flows (they
run once).
"""

from __future__ import annotations

import re

from perf_rules import ONE_TIME

ENTITY_HEAD = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?P<kind>view\s+|non-persistent\s+|persistent\s+)?"
                         r"entity\s+(?P<name>\w+\.(?:\"[^\"]+\"|\w+))", re.I)
ATTRIBUTE = re.compile(r"^\s*\"?(?P<name>\w+)\"?\s*:\s*(?P<type>\w+)(?P<rest>.*)$")
INDEX = re.compile(r"^\s*index\s+(?:\w+\s+)?(?:on\s+)?\(\s*\"?(?P<first>\w+)\"?", re.I)
DOC_HEAD = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:microflow|nanoflow|page|snippet)\s+(?P<name>[\w.]+)", re.I)
RETRIEVE = re.compile(r"\bretrieve\s+\$\w+\s+from\s+(?:database\s+)?(?P<entity>\w+\.(?:\"[^\"]+\"|\w+))(?P<tail>[^;]*)", re.I | re.S)
SOURCE = re.compile(r"\bdatabase\s+from\s+(?P<entity>\w+\.(?:\"[^\"]+\"|\w+))(?P<tail>(?:\s+where\s+(?:\[[^\]]*\]|[^,\n]*?(?=\s+sort\s+by|,|\n)))?"
                    r"(?:\s+sort\s+by\s+[\w.\"]+(?:\s+(?:asc|desc))?(?:\s*,\s*[\w.\"]+(?:\s+(?:asc|desc))?)*)?)", re.I | re.S)
# Scripts write `where [A = 1]`; DESCRIBE prints `where A = 1` up to sort by / limit / the end.
XPATH = re.compile(r"where\s*(?:\[(?P<xpath>[^\]]*)\]|(?P<bare>.*?)(?=\s+sort\s+by\b|\s+limit\b|\s+first\b|,\s*\w+\s*:|\)\s*$|$))",
                   re.I | re.S)
COMPARED = re.compile(r"(?<![\w./$'\"])\"?(?P<attr>[A-Za-z_]\w*)\"?\s*(?:<=|>=|=|<|>)")
SORT = re.compile(r"sort\s+by\s+(?P<list>[\w.\"]+(?:\s+(?:asc|desc))?(?:\s*,\s*[\w.\"]+(?:\s+(?:asc|desc))?)*)", re.I)
SKIP_TYPES = {"boolean", "binary", "hashstring", "autonumber"}


def _plain(name: str) -> str:
    return name.replace('"', "")


def entities(lines: list[str]) -> dict[str, dict]:
    """{entity: {"attributes": {name: type}, "indexed": {first columns, unique attributes}}}."""
    found: dict[str, dict] = {}
    current = None
    for line in lines:
        head = ENTITY_HEAD.match(line)
        if head:
            kind = (head.group("kind") or "persistent").strip().lower()
            current = _plain(head.group("name")) if kind == "persistent" else None
            if current:
                found[current] = {"attributes": {}, "indexed": set()}
            continue
        if current is None:
            continue
        if line.strip() == "/":
            current = None
            continue
        if re.match(r"^\s*(grant|@|/\*\*|\*)", line):
            continue
        index = INDEX.match(line)
        if index:
            found[current]["indexed"].add(index.group("first").lower())
            continue
        attribute = ATTRIBUTE.match(line)
        if attribute:
            name = attribute.group("name")
            found[current]["attributes"][name.lower()] = (name, attribute.group("type").lower())
            if re.search(r"\bunique\b", attribute.group("rest"), re.I):
                found[current]["indexed"].add(name.lower())
    return found


def uses(lines: list[str]) -> list[tuple[str, str, str, int]]:
    """(entity, attribute, document, line) for every attribute compared or sorted on."""
    text = "\n".join(lines)
    starts = [(m.start(), m.group("name")) for m in re.finditer(DOC_HEAD.pattern, text, re.I | re.M)]

    def document_at(offset: int) -> str:
        name = ""
        for start, doc in starts:
            if start > offset:
                break
            name = doc
        return name

    found = []
    for pattern in (RETRIEVE, SOURCE):
        for match in pattern.finditer(text):
            entity = _plain(match.group("entity"))
            tail = match.group("tail")
            line = text.count("\n", 0, match.start()) + 1
            names = []
            for xpath in XPATH.finditer(tail):
                # contains(Attr, ...) and starts-with(...) are left out: an index does not help them.
                condition = xpath.group("xpath") if xpath.group("xpath") is not None else xpath.group("bare")
                cleaned = re.sub(r"\b(contains|starts-with|ends-with)\s*\([^)]*\)", "", condition, flags=re.I)
                names += [m.group("attr") for m in COMPARED.finditer(cleaned)]
            for sort in SORT.finditer(tail):
                for item in sort.group("list").split(","):
                    names.append(_plain(item.strip().split()[0]).split(".")[-1])
            found += [(entity, name, document_at(match.start()), line) for name in names]
    return found


def index_findings(entity_lines: list[str], document_lines: list[str]) -> list[tuple[str, str, int]]:
    known = entities(entity_lines)
    places: dict[tuple[str, str], list[str]] = {}
    first_line: dict[tuple[str, str], int] = {}
    for entity, attr, document, line in uses(document_lines):
        info = known.get(entity)
        if not info or attr.lower() not in info["attributes"] or (document and ONE_TIME.search(document)):
            continue
        name, kind = info["attributes"][attr.lower()]
        if kind in SKIP_TYPES or attr.lower() in info["indexed"]:
            continue
        key = (entity, name)
        places.setdefault(key, [])
        if document and document not in places[key]:
            places[key].append(document)
        first_line.setdefault(key, line)
    findings = []
    for (entity, name), documents in sorted(places.items()):
        where = ", ".join(documents[:3]) + (f" and {len(documents) - 3} more" if len(documents) > 3 else "")
        findings.append(("PERF07", (
            f"{entity}.{name} is filtered or sorted on ({where or 'a retrieve'}) and no index starts with it: "
            f"every such query reads the whole table. `alter entity {entity} add index if not exists ({name});` "
            f"-- measured at 200k rows: the latest row by date 35 ms -> 0.01 ms, one status 9.7 -> 2.0 ms. An "
            f"index costs a little on every commit, so index what is filtered or sorted, not every attribute"),
            first_line[(entity, name)]))
    return findings
