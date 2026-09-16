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

A module with no page and no ACT_ microflow has nothing a user can reach, and
passes. A model that cannot be read is neither a pass nor a finding: the check
prints ERROR and exits 2.

Every module to check can be named in one call, and should be. A test may cover a
page in another module; whether that claim is real or left behind by a rename can
only be told against the whole project, so the stale-claim check always reads
every user module, whichever modules were asked about.

    check_test_coverage.py <app-dir> <Module> [<Module>...] [--tests-dir tests] [--json]

Exit 0 all covered, 1 something uncovered or stale, 2 the model could not be read.
"""

from __future__ import annotations

import argparse
import json
import re
import os
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


class ModelReadError(RuntimeError):
    """The model could not be read -- which is not the same as an empty module."""


def mxcli_json(app_dir: Path, mpr: str, command: str) -> list[dict]:
    """Run one MDL command and read its --json rows.

    A failed command used to come back as an empty list, so an unreadable model
    looked exactly like a module with nothing in it. It raises instead.
    """
    try:
        result = subprocess.run(
            [mxcli_binary(app_dir), "-p", mpr, "--json", "-c", command],
            cwd=app_dir,
            capture_output=True,
            text=True,
            # The exec hook runs this checker after every terminal command, so an
            # mxcli that never returns would hold the agent's turn open with no
            # message. A read of the model takes well under a second.
            timeout=float(os.environ.get("MDL_MXCLI_TIMEOUT", "120")),
        )
    except subprocess.TimeoutExpired as exc:
        raise ModelReadError(f"`{command}` did not finish within {exc.timeout:.0f}s") from exc
    except OSError as exc:
        raise ModelReadError(f"could not start mxcli: {exc}") from exc
    if result.returncode != 0:
        why = (result.stderr or result.stdout).strip().splitlines()
        raise ModelReadError(f"`{command}` exited {result.returncode}: {why[-1] if why else 'no output'}")
    try:
        rows = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ModelReadError(f"`{command}` did not return JSON") from exc
    if not isinstance(rows, list):
        raise ModelReadError(f"`{command}` did not return a list")
    return rows


def project_modules(app_dir: Path, mpr: str) -> tuple[set[str], list[str]]:
    """Every module name in the model, and the ones that are the project's own."""
    rows = mxcli_json(app_dir, mpr, "SHOW MODULES")
    every = {row.get("Module") for row in rows if row.get("Module")}
    own = sorted(
        row["Module"]
        for row in rows
        if row.get("Module")
        and not (row.get("Source") or "").strip()
        and row["Module"] not in ("System", "MyFirstModule")
    )
    return every, own


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
    parser.add_argument("modules", nargs="+", metavar="Module")
    parser.add_argument("--tests-dir", default="tests")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    app_dir = args.app_dir
    mprs = sorted(app_dir.glob("*.mpr"))
    if not mprs:
        print(f"ERROR  no .mpr in {app_dir}")
        return 2
    mpr = mprs[0].name

    try:
        every, own = project_modules(app_dir, mpr)
        unknown = [module for module in args.modules if module not in every]
        if unknown:
            print(f"ERROR  no module named {', '.join(unknown)} in {mpr}")
            return 2
        inventories = {module: inventory(app_dir, mpr, module)
                       for module in sorted(set(own) | set(args.modules))}
    except ModelReadError as exc:
        print(f"ERROR  could not read the model: {exc}")
        return 2

    known: set[str] = set()
    for _required, names in inventories.values():
        known |= names

    claims = covered(app_dir / args.tests_dir)
    stale = sorted(name for name in claims if name not in known)
    checked = set(args.modules)

    reports = []
    for module in args.modules:
        required = inventories[module][0]
        untested = [element for element in required if element not in claims]
        prefix = module + "."
        mine = [name for name in stale if name.startswith(prefix)]
        # A stale claim naming no module being checked -- a typo, a deleted module --
        # still has to fail somewhere. With one module asked about, it is that one's.
        if len(args.modules) == 1:
            mine = stale
        reports.append({
            "verdict": "PASS" if not untested and not mine else "FAIL",
            "module": module,
            "elements": len(required),
            "tests": sorted({script for name, scripts in claims.items()
                             if name.startswith(prefix) for script in scripts}),
            "untested": untested,
            "stale_covers": mine,
        })
    orphans = [] if len(args.modules) == 1 else [
        name for name in stale if name.split(".")[0] not in checked]

    if args.json:
        payload = reports[0] if len(reports) == 1 else {"modules": reports, "stale_covers": orphans}
        print(json.dumps(payload, indent=2))
    else:
        for report in reports:
            total, missing = report["elements"], len(report["untested"])
            if total == 0 and not report["stale_covers"]:
                print(f"PASS  {report['module']}: nothing a user can reach (no page, no ACT_ microflow)")
                continue
            print(f"{report['verdict']}  {report['module']}: {total - missing}/{total} "
                  f"elements covered by {len(report['tests'])} test script(s)")
            for element in report["untested"]:
                print(f"  - no test covers {element}")
            for name in report["stale_covers"]:
                print(f"  - covers: names {name}, which is not in the model any more")
        if orphans:
            print("FAIL  covers: lines name elements in no module of this project")
            for name in orphans:
                print(f"  - covers: names {name}, which is not in the model any more")

    failed = orphans or any(report["verdict"] == "FAIL" for report in reports)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
