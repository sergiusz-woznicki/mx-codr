#!/usr/bin/env python3
"""SCOPE01: a page's data source microflow returns rows the page's role may not read.

A microflow does not apply entity access to its own retrieves, so an access rule that scopes a
role to its own rows by XPath (`grant Customer on Invoice (read *) where '[...CurrentUser...]'`)
does not reach the rows a data source microflow hands to that role's page. A DeepSeek session's
customer portal showed another customer's invoice that way; only its verify test caught it.

Finding: page P is granted to role R and fills a widget from microflow M; M retrieves entity E
from the database with no constraint that ties it to the user (neither '[%CurrentUser%]' nor an
object variable such as `= $Customer`); and R's access rule on E carries an XPath constraint.

Usage: check_scope.py <app_dir> <Module> [<Module> ...] [--json]
Exit: 0 no finding, 1 findings, 2 the model could not be read.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DATASOURCE_RE = re.compile(r"DataSource:\s*microflow\s+([A-Za-z_]\w*\.[A-Za-z_]\w*)", re.IGNORECASE)
PAGE_GRANT_RE = re.compile(r"grant\s+view\s+on\s+page\s+\S+\s+to\s+([^;]+);", re.IGNORECASE)
# A database retrieve: `retrieve $X from Mod.Entity ...;` -- not `from $Obj/Mod.Assoc`, which the
# object scopes already.
RETRIEVE_RE = re.compile(r"\bretrieve\s+\$\w+\s+from\s+([A-Za-z_]\w*\.[A-Za-z_]\w*)\b([^;]*);", re.IGNORECASE | re.S)
ENTITY_GRANT_RE = re.compile(r"grant\s+(\S+)\s+on\s+(\S+)\s*\([^)]*\)\s*where\s+'", re.IGNORECASE)


class ModelReadError(RuntimeError):
    """The model could not be read."""


def mxcli_binary(app_dir: Path) -> str:
    for name in ("mxcli", "mxcli.exe"):
        if (app_dir / name).exists():
            return "./" + name
    return "./mxcli"


def mxcli(app_dir: Path, mpr: str, command: str, as_json: bool = False):
    """One MDL command's output: text, or the rows of its --json output."""
    args = [mxcli_binary(app_dir), "-p", mpr] + (["--json"] if as_json else []) + ["-c", command]
    try:
        result = subprocess.run(args, cwd=app_dir, capture_output=True, text=True,
                                timeout=float(os.environ.get("MDL_MXCLI_TIMEOUT", "120")))
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise ModelReadError(f"`{command}` could not run: {exc}") from exc
    if result.returncode != 0:
        why = (result.stderr or result.stdout).strip().splitlines()
        raise ModelReadError(f"`{command}` exited {result.returncode}: {why[-1] if why else 'no output'}")
    if not as_json:
        return result.stdout
    try:
        rows = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ModelReadError(f"`{command}` did not return JSON") from exc
    if not isinstance(rows, list):
        raise ModelReadError(f"`{command}` did not return a list")
    return rows


def qualified(row: dict) -> str:
    return str(row.get("Qualified Name") or row.get("QualifiedName") or "")


def unscoped_retrieves(text: str) -> list[str]:
    """Entities a microflow retrieves from the database with nothing tying them to the user."""
    entities = []
    for entity, rest in RETRIEVE_RE.findall(text):
        if "CurrentUser" in rest or re.search(r"\$\w+", rest):
            continue
        entities.append(entity)
    return entities


def scoped_roles(text: str, entity: str) -> set[str]:
    """Roles whose access rule on the entity carries an XPath constraint."""
    return {role for role, target in ENTITY_GRANT_RE.findall(text) if target == entity}


def findings(app_dir: Path, mpr: str, modules: list[str], read=mxcli) -> list[str]:
    flows: dict[str, list[str]] = {}
    entities: dict[str, str] = {}
    found = []
    for module in modules:
        for row in read(app_dir, mpr, f"SHOW PAGES IN {module}", True):
            page = qualified(row)
            if not page:
                continue
            text = read(app_dir, mpr, f"DESCRIBE PAGE {page}")
            sources = sorted(set(DATASOURCE_RE.findall(text)))
            if not sources:
                continue
            roles = set()
            for group in PAGE_GRANT_RE.findall(text):
                roles |= {r.strip() for r in group.split(",") if r.strip()}
            for flow in sources:
                if flow not in flows:
                    flows[flow] = unscoped_retrieves(read(app_dir, mpr, f"DESCRIBE MICROFLOW {flow}"))
                for entity in flows[flow]:
                    if entity not in entities:
                        entities[entity] = read(app_dir, mpr, f"DESCRIBE ENTITY {entity}")
                    for role in sorted(roles & scoped_roles(entities[entity], entity)):
                        found.append(
                            f"  - [SCOPE01] {page} shows {entity} through {flow} to {role}: {role}'s access rule "
                            f"scopes {entity} by XPath, but a microflow does not apply entity access, so {flow} "
                            f"returns every row -- constrain its retrieve the same way (e.g. "
                            f"where [...Customer_Account = '[%CurrentUser%]'], or = $TheSignedInCustomer)")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_dir", type=Path)
    parser.add_argument("modules", nargs="+")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    mprs = sorted(p.name for p in args.app_dir.glob("*.mpr"))
    if not mprs:
        print("FAIL  no .mpr in " + str(args.app_dir), file=sys.stderr)
        return 2
    try:
        found = findings(args.app_dir, mprs[0], args.modules)
    except ModelReadError as exc:
        print(f"could not run -- {exc}")
        return 2
    if args.json:
        print(json.dumps({"findings": found}, indent=2))
    else:
        print(f"{'PASS' if not found else 'WARN'}  {len(found)} data source microflow finding(s)")
        for line in found:
            print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
