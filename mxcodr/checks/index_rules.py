"""PERF07: a query the app runs often, with no database index that serves it.

    from index_rules import index_findings
    index_findings(entity_lines, document_lines) -> [(code, message, line)]

<entity_lines> is DESCRIBE ENTITY output for the project's own entities; <document_lines> is
DESCRIBE output for its microflows, nanoflows and pages. Each retrieve and page database source
wants one index: the attributes its XPath compares with `=` first, then the first one it compares
with `<`, `>`, `<=`, `>=`, or else the first it sorts by. An existing index whose leading columns
are those serves it; an index on (A, B) also serves a query on A alone, so a shorter suggestion
another one starts with is dropped, and an existing (A) that (A, B) would replace is named.
Measured at 200,000 rows, the newest order of one status: 9.9 ms with no index, 2.6 ms with an
index on each attribute, 0.01 ms with one (Status, DateCreated). Mendix indexes `id`, every association and every attribute with a uniqueness rule
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
INDEX = re.compile(r"^\s*index\s+(?:\w+\s+)?(?:on\s+)?\((?P<columns>[^)]*)\)", re.I)
DOC_HEAD = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:microflow|nanoflow|page|snippet)\s+(?P<name>[\w.]+)", re.I)
RETRIEVE = re.compile(r"\bretrieve\s+\$\w+\s+from\s+(?:database\s+)?(?P<entity>\w+\.(?:\"[^\"]+\"|\w+))(?P<tail>[^;]*)", re.I | re.S)
SOURCE = re.compile(r"\bdatabase\s+(?:from\s+)?(?P<entity>\w+\.(?:\"[^\"]+\"|\w+))(?P<tail>(?:\s+where\s+(?:\[[^\]]*\]|[^,\n]*?(?=\s+sort\s+by|,|\n)))?"
                    r"(?:\s+sort\s+by\s+[\w.\"]+(?:\s+(?:asc|desc))?(?:\s*,\s*[\w.\"]+(?:\s+(?:asc|desc))?)*)?)", re.I | re.S)
# Scripts write `where [A = 1]`; DESCRIBE prints `where A = 1` up to sort by / limit / the end.
XPATH = re.compile(r"where\s*(?:\[(?P<xpath>[^\]]*)\]|(?P<bare>.*?)(?=\s+sort\s+by\b|\s+limit\b|\s+first\b|,\s*\w+\s*:|\)\s*$|$))",
                   re.I | re.S)
COMPARED = re.compile(r"(?<![\w./$'\"])\"?(?P<attr>[A-Za-z_]\w*)\"?\s*(?P<op><=|>=|=|<|>)")
# `[$Wanted = Status]`: the attribute on the right. Not `= true`, `= empty` (no such attribute, so
# wanted() drops them), `= Module.Enum.Value` (a dot follows) or `= $Var/Attr` (starts with $).
COMPARED_RIGHT = re.compile(r"(?P<op><=|>=|=|<|>)\s*\"?(?P<attr>[A-Za-z_]\w*)\"?(?![\w.(/'\"$%])")
OR = re.compile(r"\s+or\s+", re.I)
SORT = re.compile(r"sort\s+by\s+(?P<list>[\w.\"]+(?:\s+(?:asc|desc))?(?:\s*,\s*[\w.\"]+(?:\s+(?:asc|desc))?)*)", re.I)
GRID = re.compile(r"\bdatagrid\s+\w+\s*\(\s*DataSource:\s*database\s+(?:from\s+)?(?P<entity>\w+\.(?:\"[^\"]+\"|\w+))", re.I)
COLUMN = re.compile(r"^\s*column\s+\"?\w+\"?\s*\(\s*Attribute:\s*\"?(?P<attr>\w+)", re.I)
FILTER = re.compile(r"^\s*(?P<kind>dropdownfilter|datefilter|numberfilter)\b", re.I)
VIEW_HEAD = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?view\s+entity\s+(?P<name>[\w.]+)", re.I)
# `from Orders.Invoice as i`, `inner join Orders.Order_Customer/Orders."Order" as o`: the alias of an entity.
OQL_SOURCE = re.compile(r"\b(?:from|join)\s+(?:[\w.\"]+/)*(?P<entity>\w+\.(?:\"[^\"]+\"|\w+))\s+as\s+(?P<alias>\w+)", re.I)
OQL_ORDER = re.compile(r"\border\s+by\s+(?P<list>[^;)]*)", re.I)
# `[Orders.Order_Customer = $Customer]`, `[A/B.C/D.E = $x]`: a query that follows an association,
# whose own index (Mendix makes one) narrows the rows before any attribute is read.
ASSOCIATION = re.compile(r"(?<![\w.$'\"])\w+\.\w+(?:/[\w.\"]+)*\s*=(?!=)")
SKIP_TYPES = {"boolean", "binary", "hashstring", "autonumber"}


def _plain(name: str) -> str:
    return name.replace('"', "")


def entity_heads(lines: list[str]) -> int:
    """How many `create ... entity` heads the text has, of any kind."""
    return sum(1 for line in lines if ENTITY_HEAD.match(line))


def entities(lines: list[str]) -> dict[str, dict]:
    """{entity: {"attributes": {lower: (name, type)}, "indexes": [(lower columns...)]}}; a unique
    attribute counts as an index of its own (Mendix creates one)."""
    found: dict[str, dict] = {}
    current = None
    for line in lines:
        head = ENTITY_HEAD.match(line)
        if head:
            kind = (head.group("kind") or "persistent").strip().lower()
            current = _plain(head.group("name")) if kind == "persistent" else None
            if current:
                found[current] = {"attributes": {}, "indexes": [], "explicit": []}
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
            columns = tuple(_plain(part.strip().split()[0]).lower() for part in index.group("columns").split(","))
            found[current]["indexes"].append(columns)
            found[current]["explicit"].append((columns, index.group("columns").strip()))
            continue
        attribute = ATTRIBUTE.match(line)
        if attribute:
            name = attribute.group("name")
            found[current]["attributes"][name.lower()] = (name, attribute.group("type").lower())
            if re.search(r"\bunique\b", attribute.group("rest"), re.I):
                found[current]["indexes"].append((name.lower(),))
    return found


def queries(lines: list[str]) -> list[tuple[str, list[str], list[str], list[str], str, int, bool]]:
    """(entity, attributes compared with =, compared with < > <= >=, sorted on, document, line,
    follows an association) for every retrieve, page database source and grid filter."""
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
            tail = match.group("tail")
            sort, through = [], False
            # One (equal, ranged) pair per `or` branch: `[A = 1 or B = 2]` is two lookups, each
            # wanting its own index, not one on (A, B).
            branches: list[tuple[list[str], list[str]]] = []
            for xpath in XPATH.finditer(tail):
                # contains(Attr, ...) and starts-with(...) are left out: an index does not help them.
                condition = xpath.group("xpath") if xpath.group("xpath") is not None else xpath.group("bare")
                cleaned = re.sub(r"\b(contains|starts-with|ends-with)\s*\([^)]*\)", "", condition, flags=re.I)
                cleaned = re.sub(r"'[^']*'", "''", cleaned)       # a literal is not an attribute
                through = through or bool(ASSOCIATION.search(cleaned))
                for branch in OR.split(cleaned):
                    equal, ranged = [], []
                    for compared in list(COMPARED.finditer(branch)) + list(COMPARED_RIGHT.finditer(branch)):
                        (equal if compared.group("op") == "=" else ranged).append(compared.group("attr"))
                    branches.append((equal, ranged))
            for sorted_by in SORT.finditer(tail):
                sort += [_plain(item.strip().split()[0]).split(".")[-1] for item in sorted_by.group("list").split(",")]
            alone = len(branches) <= 1
            for equal, ranged in branches or [([], [])]:
                # A sort belongs to the query as a whole; with `or` no single index gives the order.
                found.append((_plain(match.group("entity")), equal, ranged, sort if alone else [],
                              document_at(match.start()), text.count("\n", 0, match.start()) + 1, through))
    # A data grid's column filter is a query too: a drop-down filter compares with `=`, a date or
    # number filter with a range. A text filter is `contains()`, which an index does not help.
    grid, column, offset = None, None, 0
    for number, line in enumerate(text.splitlines(), 1):
        at, offset = offset, offset + len(line) + 1
        source = GRID.search(line)
        if source:
            grid = _plain(source.group("entity"))
            continue
        attribute = COLUMN.search(line)
        if attribute:
            column = attribute.group("attr")
            continue
        widget = FILTER.search(line)
        if widget and grid and column:
            kind = widget.group("kind").lower()
            equal, ranged = ([column], []) if kind == "dropdownfilter" else ([], [column])
            found.append((grid, equal, ranged, [], document_at(at), number, False))
            column = None
    return found


def oql_queries(entity_lines: list[str]) -> list[tuple[str, list[str], list[str], list[str], str, int, bool]]:
    """The queries in view entities' OQL, one per alias of an entity it reads: `i.Status = 'x'`
    compares with `=`, `i.DueDate < ...` with a range, `order by i.Date` sorts. A view's query
    runs every time a page or a retrieve reads the view. Pi kept a (DueDate) index that two views
    filter on, and PERF08 called it unused because it read no OQL (2026-10-04)."""
    found = []
    view, body, start = None, [], 0
    for number, line in enumerate(entity_lines + ["/"], 1):
        head = VIEW_HEAD.match(line)
        if head or line.strip() == "/" or ENTITY_HEAD.match(line):
            if view and body:
                text = "\n".join(body)
                for source in OQL_SOURCE.finditer(text):
                    alias = re.escape(source.group("alias"))
                    equal, ranged, sort = [], [], []
                    for compared in re.finditer(rf"(?<![\w.]){alias}\.\"?(?P<attr>\w+)\"?\s*(?P<op><=|>=|=|<|>)", text):
                        (equal if compared.group("op") == "=" else ranged).append(compared.group("attr"))
                    for order in OQL_ORDER.finditer(text):
                        sort += [m.group(1) for m in re.finditer(rf"(?<![\w.]){alias}\.\"?(\w+)", order.group("list"))]
                    through = bool(re.search(rf"(?<![\w.]){alias}/\w+\.", text))
                    found.append((_plain(source.group("entity")), equal, ranged, sort, view, start, through))
            view, body, start = (head.group("name"), [], number) if head else (None, [], 0)
            continue
        if view:
            body.append(line)
    return found


def wanted(info: dict, equal: list[str], ranged: list[str], sort: list[str]) -> tuple[str, ...]:
    """The index one query wants: its `=` attributes first, then its first range or sort attribute
    (a B-tree serves equality on the leading columns, then one range or the order). At most three."""
    def usable(names):
        out = []
        for attr in names:
            entry = info["attributes"].get(attr.lower())
            if entry and entry[1] not in SKIP_TYPES and entry[0] not in out:
                out.append(entry[0])
        return out
    columns = usable(equal)
    tail = usable(ranged)[:1] or usable(sort)[:1]
    columns += [name for name in tail if name not in columns]
    return tuple(columns[:3])


def index_findings(entity_lines: list[str], document_lines: list[str]) -> list[tuple[str, str, int]]:
    known = entities(entity_lines)
    places: dict[tuple[str, tuple[str, ...]], list[str]] = {}
    first_line: dict[tuple[str, tuple[str, ...]], int] = {}
    for entity, equal, ranged, sort, document, line, through in queries(document_lines) + oql_queries(entity_lines):
        info = known.get(entity)
        # A query along an association is served by the association's index: Mendix model indexes
        # cannot include it, and an attribute index adds little after it.
        if not info or through or (document and ONE_TIME.search(document)):
            continue
        columns = wanted(info, equal, ranged, sort)
        if not columns:
            continue
        key = (entity, columns)
        places.setdefault(key, [])
        if document and document not in places[key]:
            places[key].append(document)
        first_line.setdefault(key, line)

    def lower(columns):
        return tuple(name.lower() for name in columns)

    def covered(entity, columns):
        return any(index[:len(columns)] == lower(columns) for index in known[entity]["indexes"])

    keys = [key for key in places if not covered(*key)]
    # An index on (A, B) also serves a query on A alone: drop a suggestion another one starts with.
    keys = [(entity, columns) for entity, columns in keys
            if not any(other_entity == entity and len(other) > len(columns) and other[:len(columns)] == columns
                       for other_entity, other in keys)]
    findings = []
    for entity, columns in sorted(keys):
        documents = list(places[(entity, columns)])
        for other_entity, other in places:     # the places of the queries this index also serves
            if other_entity == entity and len(other) < len(columns) and columns[:len(other)] == other:
                documents += [d for d in places[(other_entity, other)] if d not in documents]
        where = ", ".join(documents[:3]) + (f" and {len(documents) - 3} more" if len(documents) > 3 else "")
        listed = ", ".join(columns)
        add = f"`alter entity {entity} add index if not exists ({listed});`"
        if len(columns) == 1:
            message = (f"{entity}.{columns[0]} is filtered or sorted on ({where or 'a retrieve'}) and no index "
                       f"starts with it: every such query reads the whole table. {add} -- measured at 200k rows: "
                       f"the latest row by date 35 ms -> 0.01 ms, one status 9.7 -> 2.0 ms. An index costs a "
                       f"little on every commit, so index what is filtered or sorted, not every attribute")
        else:
            # Only an index the model declares can be dropped: a `unique` attribute has one Mendix
            # made itself, and "drop index (Code)" for it named an index nobody created.
            replaced = [index for index, _ in known[entity]["explicit"]
                        if len(index) < len(columns) and lower(columns)[:len(index)] == index]
            drop = "".join(f" then `alter entity {entity} drop index if exists ({', '.join(c for c in columns[:len(index)])});`, which it replaces."
                           for index in replaced)
            message = (f"{entity} is filtered on {', '.join(columns[:-1])} and filtered or sorted on {columns[-1]} in "
                       f"one query ({where or 'a retrieve'}): one index ({listed}) serves it, the `=` attributes "
                       f"first -- {add}{drop} Measured at 200k rows, the newest order of one status: 9.9 ms with no "
                       f"index, 2.6 ms with an index on each attribute, 0.01 ms with one (Status, DateCreated). It "
                       f"also serves queries on {columns[0]} alone")
        findings.append(("PERF07", message, first_line[(entity, columns)]))
    return findings


def match_length(index: tuple[str, ...], want: tuple[str, ...]) -> int:
    """How many leading columns of <index> the query that wants <want> can use."""
    length = 0
    for have, needed in zip(index, want):
        if have != needed:
            break
        length += 1
    return length


def redundant_findings(entity_lines: list[str], document_lines: list[str]) -> list[tuple[str, str, int]]:
    """PERF08: an index of the model that no query needs. Another index that starts with the same
    columns serves everything it does; or no retrieve, page data source or grid filter uses it
    better than another index. Pi kept (CapturedOn) and (DueDate) after adding (Currency,
    CapturedOn) and (PaymentStatus, DueDate) for the same queries: each slows every commit."""
    known = entities(entity_lines)
    wants: dict[str, list[tuple[str, ...]]] = {}
    for entity, equal, ranged, sort, document, _, _ in queries(document_lines) + oql_queries(entity_lines):
        info = known.get(entity)
        if not info or (document and ONE_TIME.search(document)):
            continue
        columns = wanted(info, equal, ranged, sort)
        if columns:
            wants.setdefault(entity, []).append(tuple(name.lower() for name in columns))
    # No query recognised anywhere is not "no query needs an index": it is a describe format this
    # file does not read, and every index of the model would be called unneeded.
    if not wants:
        return []
    findings = []
    for entity, info in sorted(known.items()):
        explicit = info["explicit"]
        for position, (columns, spelled) in enumerate(explicit):
            longer = [other_spelled for i, (other, other_spelled) in enumerate(explicit)
                      if i != position and other[:len(columns)] == columns and (len(other) > len(columns) or i < position)]
            drop = f"`alter entity {entity} drop index if exists ({spelled});`"
            if longer:
                reason = (f"the index ({longer[0]}) starts with the same columns and serves every "
                          f"query this one does")
            else:
                # Every other index: the explicit ones but this, and the unique attributes' own.
                others = [other for i, (other, _) in enumerate(explicit) if i != position] + \
                         [index for index in info["indexes"] if index not in [e for e, _ in explicit]]
                needed = any(match_length(columns, want) > 0 and
                             match_length(columns, want) >= max([match_length(o, want) for o in others] or [0])
                             for want in wants.get(entity, []))
                if needed:
                    continue
                reason = ("no retrieve, page data source, grid filter or view entity in the model needs it: another index "
                          "serves each query that touches these columns, or none does")
            findings.append(("PERF08", (
                f"{entity} has the index ({spelled}), but {reason}. It only slows every commit: {drop} "
                f"-- keep it if Java, an OQL query outside a view or an external client filters on it"), 0))
    return findings
