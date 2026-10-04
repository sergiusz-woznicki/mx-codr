"""VIEW01: a view entity that hands a row-scoped role every row of the data it summarises.

    python3 view_access.py <entities.mdl>

<entities.mdl> is DESCRIBE ENTITY output for the project's own entities, one after another.
A role that reads only its own rows of an entity (an access rule with an XPath constraint) must
not read a view over that entity without a constraint: the view returns the
totals of every customer. InvoiceB2B (2026-10-04) granted its Customer role `read *` on two
views that sum every customer's orders and invoices, while the same role saw only its own
invoices. Prints one line per finding; exit 1 when there is one, 0 when none, 2 when it could
not run.
"""

from __future__ import annotations

import re
import sys

HEAD = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?P<kind>view\s+|(?:non-)?persistent\s+)?"
                  r"entity\s+(?P<name>[\w.]+)", re.I)
GRANT = re.compile(r"^\s*grant\s+(?P<role>[\w.]+)\s+on\s+(?P<entity>[\w.]+)\s*\((?P<rights>[^)]*)\)"
                   r"(?P<where>\s+where\s+')?", re.I)
SOURCE = re.compile(r"\b(?:from|join)\s+(?P<entity>\w+\.(?:\"[^\"]+\"|\w+))", re.I)


def _name(text: str) -> str:
    return text.replace('"', "")


def read(lines: list[str]):
    """({view: [entities its query reads]}, {(role, entity): constrained?} for rules that read)."""
    views: dict[str, list[str]] = {}
    rules: dict[tuple[str, str], bool] = {}
    current, in_query = None, False
    for line in lines:
        head = HEAD.match(line)
        if head:
            current = head.group("name")
            in_query = bool(head.group("kind")) and head.group("kind").lower().startswith("view")
            if in_query:
                views[current] = []
            continue
        grant = GRANT.match(line)
        if grant:
            in_query = False
            if "read" in grant.group("rights").lower():
                key = (grant.group("role"), grant.group("entity"))
                # Two rules for one role: the unconstrained one wins, as at runtime.
                rules[key] = rules.get(key, True) and bool(grant.group("where"))
            continue
        if in_query and current in views:
            for match in SOURCE.finditer(line):
                entity = _name(match.group("entity"))
                if entity not in views[current]:
                    views[current].append(entity)
    return views, rules


def findings(lines: list[str]) -> list[str]:
    views, rules = read(lines)
    found = []
    for view, sources in views.items():
        for (role, entity), constrained in sorted(rules.items()):
            if entity != view or constrained:
                continue
            # Only a constrained rule: the role sees its own rows. A role with no rule on the source
            # at all (a manager reading dashboard totals) is not row-scoped, so its view is fine.
            hidden = [source for source in sources if source != view and rules.get((role, source)) is True]
            if not hidden:
                continue
            found.append(
                f"[VIEW01] {role} reads every row of the view {view} with no XPath constraint, but sees "
                f"only its own rows of {', '.join(hidden)}: the view hands it every other "
                f"customer's figures. Either constrain the rule (`grant {role} on {view} (read *) where "
                f"'[...]';` over a column that identifies the signed-in user's rows), or `revoke {role} on "
                f"{view};` and let the page's data-source microflow read the view without entity access, "
                f"filtered to the object the role may see (skill manage-security)")
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    # 2, not a traceback's 1: the gate reads 1 as "findings".
    try:
        with open(argv[1], encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        out = findings(lines)
    except Exception as exc:  # noqa: BLE001 -- whatever stopped it, the model was not checked
        print(f"view_access.py could not run: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    for line in out:
        print(line)
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
