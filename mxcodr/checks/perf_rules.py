"""Performance rules for described microflows: work a database does in one query, done row by
row in a microflow instead. Part of check_mdl.py --skill naming; warnings, never failures.

    PERF02  a loop over a list retrieved from the database only adds up or counts its rows
    PERF03  inside such a loop, a database call per row: a retrieve from the database or over
            the row's association, a Java action, or a microflow that reads or writes the database
    PERF05  a whole table is retrieved and the loop keeps rows with an `if` -- a filter the
            retrieve's XPath should do
    PERF06  the loop only keeps the largest or smallest value of its rows (the next number,
            the latest date) -- one sorted retrieve with `limit 1` returns that row

Measured 2026-10-04 on InvoiceB2B, 10,680 orders and 2,360 invoices of one customer: the
customer panel computed in loops took 160 ms; the same figures as count()/sum() right after a
retrieve, 159 ms (each figure its own query through the joins); one OQL view entity, 60 ms. So
the advice for totals and counts is the view, not the aggregate. One-time seed and demo-data
flows (ASU_, *Seed*, *Demo*) are not judged: they run once.
"""

from __future__ import annotations

import re

FLOW_HEAD = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:microflow|nanoflow)\s+(?P<name>[\w.]+)", re.I)
RETRIEVE = re.compile(r"^\s*retrieve\s+\$(?P<var>\w+)\s+from\s+(?:database\s+)?(?P<src>[^\s;]+)(?P<rest>.*)$", re.I)
LOOP = re.compile(r"^\s*loop\s+\$(?P<item>\w+)\s+in\s+\$(?P<list>\w+)", re.I)
WHILE = re.compile(r"^\s*while\b", re.I)
END_LOOP = re.compile(r"^\s*end\s+(?:loop|while)\s*;", re.I)
# `set` is optional: `$Sum = $Sum + ...` assigns too (Pi wrote it that way and PERF02 missed it).
# Not a line with a string literal: `$Text = $Text + $O/Code + ','` builds a text, it sums nothing.
ACCUM = re.compile(r"^\s*(?:set\s+)?\$(?P<var>\w+)\s*=\s*\$(?P=var)\s*[-+][^']*$", re.I)
TRAILING_COMMENT = re.compile(r"^((?:[^'-]|'[^']*'|-(?!-))*?)\s+--.*$")
SET = re.compile(r"^\s*(?:set\s+)?\$\w+\s*=(?!=)", re.I)
COMPARE = re.compile(r"^\s*(?:if|elsif)\s+\$(?P<a>\w+)(?:/\w+)?\s*(?P<op>>=?|<=?)\s*\$(?P<b>\w+)(?:/\w+)?\s+then", re.I)
KEEP = re.compile(r"^\s*(?:set\s+)?\$(?P<to>\w+)\s*=\s*\$(?P<from>\w+)(?:/\w+)?\s*;", re.I)
CALL = re.compile(r"\bcall\s+(?P<kind>microflow|nanoflow|java\s+action)\s+(?P<name>[\w.]+)", re.I)
WRITE = re.compile(r"^\s*(?:\$\w+\s*=\s*)?(change|commit|delete|rollback|create|add|remove|show\s+page|"
                   r"close\s+page|show\s+message|validation\s+feedback|download|send|import|export|"
                   r"execute|call\s+rest|call\s+web)\b", re.I)
CONTROL = re.compile(r"^\s*(if\b|else\b|elsif\b|end\s+if|declare\b|begin\b|end\s*;|return\b|case\b|"
                     r"when\b|end\s+case|log\b)", re.I)
IF_ON_ITEM = r"^\s*(?:if|elsif)\b.*\$%s/"
ONE_TIME = re.compile(r"(^|\.)ASU_|seed|demo", re.I)

VIEW_FIX = ("compute totals and counts in the database: an OQL view entity returns them in one "
            "query (give the view entity access rules with an XPath constraint). Measured at 10k "
            "rows: the view 60 ms, this loop 160 ms; count()/sum() right after the retrieve was "
            "no faster (159 ms)")


def _statements(lines: list[str]) -> dict[str, list[tuple[int, str]]]:
    """{flow: [(line number, statement)]}: continuation lines joined, annotations dropped."""
    flows: dict[str, list[tuple[int, str]]] = {}
    name, buffer, start = None, "", 0
    for index, raw in enumerate(lines, 1):
        # A comment after a statement would hide its `;`, and the next line joined it: a retrieve
        # followed by `loop` on the next line became one statement, and the loop was lost.
        stripped = TRAILING_COMMENT.sub(r"\1", raw.strip())
        head = FLOW_HEAD.match(stripped)
        if head:
            name, buffer = head.group("name"), ""
            flows[name] = []
            continue
        if name is None or not stripped or stripped.startswith(("@", "--", "/**", "*", "grant ")):
            continue
        if not buffer:
            start = index
        buffer = (buffer + " " + stripped).strip()
        if buffer.endswith((";", "begin", "then")) or re.match(r"^(else|end)\b", buffer, re.I):
            flows[name].append((start, buffer))
            buffer = ""
    return flows


def _db_lists(statements: list[tuple[int, str]]) -> dict[str, tuple[str, bool]]:
    """{list var: (entity, whole table)} for retrieves from the database (not over a path)."""
    found = {}
    for _, text in statements:
        match = RETRIEVE.match(text)
        if match and not match.group("src").startswith("$"):
            found[match.group("var")] = (match.group("src"), not re.search(r"\bwhere\b", text, re.I))
    return found


def _loops(statements: list[tuple[int, str]]):
    """(line, item, list, body statements) for every loop, nested ones included."""
    for index, (line, text) in enumerate(statements):
        match = LOOP.match(text)
        if not match:
            continue
        depth, body = 0, []
        for inner in statements[index + 1:]:
            if LOOP.match(inner[1]) or WHILE.match(inner[1]):
                depth += 1
            if END_LOOP.match(inner[1]):
                if depth == 0:
                    break
                depth -= 1
            body.append(inner[1])
        yield line, match.group("item"), match.group("list"), body


def _touches_db(statements: list[tuple[int, str]]) -> bool:
    return any(RETRIEVE.match(t) and not RETRIEVE.match(t).group("src").startswith("$")
               or re.match(r"^\s*(commit|delete)\b", t, re.I) for _, t in statements)


def _keeps_extreme(body: list[str]) -> bool:
    """True when an `if $a > $b then` is followed by `$b = $a` (or the other way round)."""
    for index, text in enumerate(body):
        compare = COMPARE.match(text)
        if not compare:
            continue
        pair = {compare.group("a").lower(), compare.group("b").lower()}
        for after in body[index + 1:index + 3]:
            keep = KEEP.match(after)
            if keep and {keep.group("to").lower(), keep.group("from").lower()} == pair:
                return True
    return False


def perf_findings(lines: list[str]) -> list[tuple[str, str, int]]:
    """(code, message, line) for every finding."""
    flows = _statements(lines)
    findings: list[tuple[str, str, int]] = []
    for name, statements in flows.items():
        if ONE_TIME.search(name):
            continue
        where = (" -- it is a page's data source, so this runs every time the page opens"
                 if re.search(r"(^|\.)DS_", name) else "")
        db_lists = _db_lists(statements)
        for line, item, lst, body in _loops(statements):
            if lst not in db_lists:
                continue
            entity, whole = db_lists[lst]
            accumulated = sorted({ACCUM.match(t).group("var") for t in body if ACCUM.match(t)})
            writes = [t for t in body if WRITE.match(t)]
            per_row: list[str] = []
            for text in body:
                retrieve = RETRIEVE.match(text)
                if retrieve and retrieve.group("src").startswith("$" + item + "/"):
                    per_row.append("retrieves over " + retrieve.group("src"))
                elif retrieve and not retrieve.group("src").startswith("$"):
                    per_row.append("retrieves from " + retrieve.group("src"))
                call = CALL.search(text)
                if call:
                    callee = flows.get(call.group("name"))
                    if call.group("kind").lower().startswith("java"):
                        per_row.append("calls Java action " + call.group("name"))
                    elif callee is not None and _touches_db(callee):
                        per_row.append("calls " + call.group("name") + ", which reads or writes the database")
            others = [t for t in body if not (ACCUM.match(t) or SET.match(t) or CONTROL.match(t)
                                              or CALL.search(t) or RETRIEVE.match(t))]
            if accumulated and not writes and not others and not per_row:
                findings.append(("PERF02", (
                    f"{name}: the loop over ${lst} ({entity}) only adds up "
                    f"{', '.join('$' + v for v in accumulated)}: every row is read into memory to be "
                    f"summed -- {VIEW_FIX}{where}"), line))
            if per_row:
                findings.append(("PERF03", (
                    f"{name}: the loop over ${lst} ({entity}) {'; '.join(sorted(set(per_row)))} for every "
                    f"row -- one database call per row (N+1). Get what the loop needs in one retrieve "
                    f"before it (an XPath over the association), or compute it in an OQL view{where}"), line))
            if not accumulated and not writes and not others and not per_row and _keeps_extreme(body):
                findings.append(("PERF06", (
                    f"{name}: the loop over ${lst} ({entity}) reads every row to keep the largest or "
                    f"smallest value -- retrieve only that row, sorted: `retrieve $Last from {entity} "
                    f"where [...] sort by {entity}.<Attr> desc limit 1;` (`asc` for the smallest){where}"), line))
            if whole and any(re.match(IF_ON_ITEM % re.escape(item), t, re.I) for t in body):
                findings.append(("PERF05", (
                    f"{name}: retrieves all of {entity} and keeps rows with an `if` in the loop -- put "
                    f"that condition in the retrieve: `retrieve ${lst} from {entity} where [...];`, so "
                    f"the database returns only those rows{where}"), line))
    return findings
