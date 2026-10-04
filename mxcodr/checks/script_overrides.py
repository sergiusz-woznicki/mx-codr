"""After an `mxcli exec`: what the scripts it ran put back that another script had changed.

    python3 script_overrides.py --command '<the shell command>'

Reads the .mdl scripts the command names and the other .mdl scripts beside them. Re-running an
older script undoes a later one: `create or modify page` drops every `alter page` another script
made to that page, and a `grant` puts back access another script revoked. InvoiceB2B
(2026-10-04): re-running 07_dashboard.mdl granted the Dashboard to Employee again, which
20_access.mdl had taken away, and a test failed on it. Prints the advice, or nothing. Exit 0.
"""

from __future__ import annotations

import glob
import os
import re
import shlex
import sys

KIND = r"(microflow|nanoflow|page|snippet)"
DOC_GRANT = re.compile(rf"^\s*grant\s+(execute|view)\s+on\s+{KIND}\s+([\w.]+)\s+to\s+([^;]+);", re.I)
DOC_REVOKE = re.compile(rf"^\s*revoke\s+(execute|view)\s+on\s+{KIND}\s+([\w.]+)\s+from\s+([^;]+);", re.I)
ENTITY_GRANT = re.compile(r"^\s*grant\s+([\w.]+)\s+on\s+([\w.]+)\s*\(", re.I)
ENTITY_REVOKE = re.compile(r"^\s*revoke\s+([\w.]+)\s+on\s+([\w.]+)\s*;", re.I)
CREATE_PAGE = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(page|snippet)\s+([\w.]+)", re.I)
ALTER_PAGE = re.compile(r"^\s*alter\s+(page|snippet)\s+([\w.]+)", re.I)


def _roles(text: str) -> list[str]:
    return [role.strip() for role in text.split(",") if role.strip()]


def operations(path: str):
    """[(op, key)] in script order: op is grant, revoke, create or alter."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return []
    found = []
    for line in lines:
        match = DOC_GRANT.match(line)
        if match:
            found += [("grant", (f"{match.group(1).lower()} on {match.group(2).lower()} {match.group(3)}", role))
                      for role in _roles(match.group(4))]
            continue
        match = DOC_REVOKE.match(line)
        if match:
            found += [("revoke", (f"{match.group(1).lower()} on {match.group(2).lower()} {match.group(3)}", role))
                      for role in _roles(match.group(4))]
            continue
        match = ENTITY_GRANT.match(line)
        if match:
            found.append(("grant", (f"access to {match.group(2)}", match.group(1))))
            continue
        match = ENTITY_REVOKE.match(line)
        if match:
            found.append(("revoke", (f"access to {match.group(2)}", match.group(1))))
            continue
        match = CREATE_PAGE.match(line)
        if match:
            found.append(("create", f"{match.group(1).lower()} {match.group(2)}"))
            continue
        match = ALTER_PAGE.match(line)
        if match:
            found.append(("alter", f"{match.group(1).lower()} {match.group(2)}"))
    return found


SET = re.compile(r"^set\s+(?:\((?P<many>.*)\)|(?P<one>.+?))\s+on\s+\w+\s*;?$", re.I | re.S)


def _alter_block(path: str, key: str) -> list[str]:
    """The statements inside the `alter <page|snippet> <name> { ... };` blocks of <path>."""
    kind, name = key.split(" ", 1)
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return []
    found = []
    for block in re.finditer(rf"^\s*alter\s+{kind}\s+{re.escape(name)}\s*\{{(?P<body>.*?)^\s*\}};?", text, re.I | re.M | re.S):
        found += [part.strip() for part in block.group("body").split(";") if part.strip()
                  and not part.strip().startswith("--")]
    return found


def _already_in(alter_path: str, key: str, create_path: str) -> bool:
    """True when the alter only sets properties, and the creating script already has each value:
    a session moved `set (Height = 360) on chart` into the page source and kept the old alter."""
    statements = _alter_block(alter_path, key)
    try:
        source = open(create_path, encoding="utf-8").read()
    except OSError:
        return False
    if not statements:
        return False
    for statement in statements:
        match = SET.match(statement)
        if not match:
            return False        # insert, drop, replace: the page source cannot be compared
        for pair in re.split(r",\s*(?=\w+\s*=)", match.group("many") or match.group("one")):
            prop, _, value = pair.partition("=")
            if not re.search(rf"\b{re.escape(prop.strip())}\s*:\s*{re.escape(value.strip())}", source, re.I):
                return False
    return True


def scripts_in(command: str) -> list[str]:
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    paths = []
    for word in words:
        for path in (sorted(glob.glob(word))[:200] if any(c in word for c in "*?[") else [word]):
            if path.endswith(".mdl") and os.path.isfile(path) and path not in paths:
                paths.append(path)
    return paths


def findings(executed: list[str]) -> list[str]:
    """What the scripts, replayed in name order (01_, 02_, ...), leave changed that this exec undid."""
    net: dict = {}
    for path in executed:
        for op, key in operations(path):
            net[key] = op           # the last word wins: a script that creates, then alters, keeps it
    run = {os.path.abspath(path) for path in executed}
    every = sorted({os.path.abspath(path) for script in executed
                    for path in glob.glob(os.path.join(os.path.dirname(script) or ".", "*.mdl"))} | run,
                   key=os.path.basename)
    final: dict = {}                 # key -> (op, script) after replaying every script in order
    alters: dict = {}                # page -> [scripts that alter it after its last create]
    creator: dict = {}               # page -> the script that creates it last
    for path in every:
        for op, key in operations(path):
            final[key] = (op, path)
            if op == "create":
                alters[key] = []
                creator[key] = path
            elif op == "alter":
                alters.setdefault(key, []).append(path)
    found = []
    for key, op in net.items():
        if op == "grant" and final.get(key, ("", ""))[0] == "revoke" and final[key][1] not in run:
            what, role = key
            found.append(f"{os.path.basename(final[key][1])} revokes {what} from {role}; this exec granted it again")
        elif op == "create":
            for path in alters.get(key, []):
                if path not in run and not _already_in(path, key, creator[key]):
                    found.append(f"{os.path.basename(path)} alters {key}; this exec re-created the "
                                 f"{key.split()[0]} without that change")
    return list(dict.fromkeys(found))


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "--command":
        print(__doc__, file=sys.stderr)
        return 0
    executed = scripts_in(argv[2])
    if not executed:
        return 0
    found = findings(executed)
    if found:
        print("That exec put back what another script had changed:")
        for line in found[:8]:
            print("   - " + line)
        if len(found) > 8:
            print(f"   ... 8 of {len(found)} shown")
        print("   Exec those scripts again after this one, or move their change into the script that "
              "owns the page or the rule, so re-running it keeps the change.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
