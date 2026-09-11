#!/usr/bin/env python3
"""Check that every user-facing feature in a module has an end-to-end test.

The inventory comes from the model itself, never from a hand-kept list: pages and
`ACT_` microflows are the surface a user can actually reach, so each one needs a
`tests/verify-*.test.sh` script that names it.

A script declares what it exercises in a header comment, which is the whole
contract:

    #!/usr/bin/env bash
    # covers: InvoiceDesk.Invoice_Overview, InvoiceDesk.ACT_Invoice_SendReminder

Two things fail the check: an element no test covers, and a `covers:` naming an
element that is not in the model any more -- a test left behind after a rename,
which otherwise keeps passing while testing nothing.

    check_test_coverage.py <app-dir> <Module> [--tests-dir tests] [--json]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

COVERS_RE = re.compile(r"^\s*#\s*covers\s*:\s*(.+)$", re.IGNORECASE | re.MULTILINE)


def mxcli_binary(app_dir: Path) -> str:
    """The project's own mxcli, under whichever name this platform uses."""
    if (app_dir / "mxcli").exists():
        return "./mxcli"
    if (app_dir / "mxcli.exe").exists():
        return "./mxcli.exe"
    return "./mxcli"


def mxcli_json(app_dir: Path, mpr: str, command: str) -> list[dict]:
    """Run one MDL command and read its --json rows."""
    result = subprocess.run(
        [mxcli_binary(app_dir), "-p", mpr, "--json", "-c", command],
        cwd=app_dir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    try:
        rows = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []
    return rows if isinstance(rows, list) else []


def qualified_names(rows: list[dict]) -> list[str]:
    names = []
    for row in rows:
        name = row.get("Qualified Name") or row.get("QualifiedName")
        if name:
            names.append(name)
    return names


def inventory(app_dir: Path, mpr: str, module: str) -> tuple[list[str], set[str]]:
    """Two sets: what must be covered, and what may legitimately be named.

    Required is the surface a user can reach -- every page and every ACT_
    microflow. Known is everything a test could reasonably say it exercises, so a
    `covers:` naming a SUB_ or VAL_ flow is extra credit rather than an error;
    only a name that is in neither is a test left behind by a rename.
    """
    pages = qualified_names(mxcli_json(app_dir, mpr, f"SHOW PAGES IN {module}"))
    flows = qualified_names(mxcli_json(app_dir, mpr, f"SHOW MICROFLOWS IN {module}"))
    snippets = qualified_names(mxcli_json(app_dir, mpr, f"SHOW SNIPPETS IN {module}"))
    required = sorted(set(pages + [f for f in flows if f.split(".")[-1].startswith("ACT_")]))
    known = set(pages) | set(flows) | set(snippets)
    return required, known


def covered(tests_dir: Path) -> dict[str, list[str]]:
    """Element -> the test scripts claiming to cover it."""
    claims: dict[str, list[str]] = {}
    if not tests_dir.is_dir():
        return claims
    for script in sorted(tests_dir.glob("verify-*.test.sh")):
        text = script.read_text(encoding="utf-8", errors="replace")
        for match in COVERS_RE.finditer(text):
            for element in match.group(1).split(","):
                element = element.strip()
                if element:
                    claims.setdefault(element, []).append(script.name)
    return claims


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_dir", type=Path)
    parser.add_argument("module")
    parser.add_argument("--tests-dir", default="tests")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    app_dir = args.app_dir
    mprs = sorted(app_dir.glob("*.mpr"))
    if not mprs:
        print(f"FAIL  no .mpr in {app_dir}", file=sys.stderr)
        return 1
    mpr = mprs[0].name

    elements, known = inventory(app_dir, mpr, args.module)
    if not elements:
        print(f"FAIL  module {args.module} has no pages or ACT_ microflows in {mpr}", file=sys.stderr)
        return 1

    claims = covered(app_dir / args.tests_dir)

    untested = [element for element in elements if element not in claims]
    # A covers: line pointing at something the model no longer has is a test that
    # survived a rename and now proves nothing.
    stale = sorted(name for name in claims if name not in known)

    report = {
        "verdict": "PASS" if not untested and not stale else "FAIL",
        "module": args.module,
        "elements": len(elements),
        "tests": sorted({script for scripts in claims.values() for script in scripts}),
        "untested": untested,
        "stale_covers": stale,
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(
            f"{report['verdict']}  {len(elements) - len(untested)}/{len(elements)} "
            f"elements covered by {len(report['tests'])} test script(s)"
        )
        for element in untested:
            print(f"  - no test covers {element}")
        for name in stale:
            print(f"  - covers: names {name}, which is not in {args.module} any more")

    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
