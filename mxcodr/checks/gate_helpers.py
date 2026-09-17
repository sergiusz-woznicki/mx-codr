#!/usr/bin/env python3
"""The Python that tests/gate.sh needs, one subcommand per job.

    gate_helpers.py qualified-names               names from a SHOW ... --json listing on stdin
    gate_helpers.py fingerprint <path>...         one digest over files, meta:<path> and env:NAME=value
    gate_helpers.py secret                        a random 32-hex-digit cache secret
    gate_helpers.py signed-in-users               user names from an M2EE get_logged_in_user_names answer on stdin
    gate_helpers.py recent-refusal [seconds]      timestamp of a session-cap refusal line on stdin, if recent (120)
    gate_helpers.py deployment-age <mpr> <built>  warn when the model is newer than the built deployment
    gate_helpers.py runtime-age <mpr> <lstart>    warn when the model changed after the runtime started
    gate_helpers.py missing-browser <config>      the executablePath a Playwright config names, if it is missing

Exit 0 unless noted: qualified-names exits 1 when stdin is not a JSON list.
Warnings are printed to stdout, ready to show under the gate's output.
"""
import datetime
import hashlib
import json
import os
import re
import secrets
import sys


def qualified_names():
    rows = json.load(sys.stdin)
    if not isinstance(rows, list):
        return 1
    for row in rows:
        name = row.get("Qualified Name") or row.get("QualifiedName")
        if name:
            print(name)
    return 0


def fingerprint(paths):
    """Content of each file (size + mtime for meta:<path>), walked in sorted order."""
    digest = hashlib.sha256()

    def add(path, content):
        try:
            st = os.stat(path)
        except OSError:
            digest.update(("missing %s\n" % path).encode())
            return
        if os.path.isdir(path):
            for root, dirs, files in os.walk(path):
                dirs.sort()
                for name in sorted(files):
                    add(os.path.join(root, name), content)
            return
        if not content:
            digest.update(("%s %d %d\n" % (path, st.st_size, st.st_mtime_ns)).encode())
            return
        digest.update(("%s %d\n" % (path, st.st_size)).encode())
        try:
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(chunk)
        except OSError:
            digest.update(("unreadable %s\n" % path).encode())

    for arg in paths:
        if arg.startswith("env:"):
            # A setting read from the environment rather than a file; the caller expands the
            # value, so it counts whether or not it was exported.
            digest.update(("%s\n" % arg).encode())
        elif arg.startswith("meta:"):
            add(arg[5:], False)
        else:
            add(arg, True)
    print(digest.hexdigest()[:24])
    return 0


def secret():
    print(secrets.token_hex(16))
    return 0


def signed_in_users():
    try:
        feedback = json.load(sys.stdin).get("feedback", {})
    except Exception:
        return 0
    users = feedback.get("users") or []
    if users:
        print(",".join(users))
    return 0


def recent_refusal(seconds):
    line = sys.stdin.read().strip()
    stamp = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", line) if line else None
    if not stamp:
        return 0
    when = datetime.datetime.strptime(stamp.group(1), "%Y-%m-%d %H:%M:%S")
    if (datetime.datetime.now() - when).total_seconds() <= seconds:
        print(stamp.group(1))
    return 0


def deployment_age(mpr, built):
    try:
        gap = int(os.path.getmtime(mpr) - os.path.getmtime(built))
    except OSError:
        return 0
    if gap > 5:
        print("   !! the model is %ds newer than the built deployment -- this run measures"
              " the OLD app" % gap)
        print("      rebuild before trusting anything green here")
    return 0


def runtime_age(mpr, started):
    try:
        boot = datetime.datetime.strptime(" ".join(started.split()), "%a %b %d %H:%M:%S %Y")
    except ValueError:
        return 0
    changed = datetime.datetime.fromtimestamp(os.path.getmtime(mpr))
    gap = (changed - boot).total_seconds()
    if gap > 5:
        print("   !! the model changed %ds after the runtime started and nothing applied it"
              " (no --watch reload or restart logged) -- this run measures the old app:" % gap)
        print("      bash tests/gate.sh --restart")
    return 0


def missing_browser(config):
    try:
        options = json.load(open(config))["browser"]["launchOptions"]
    except Exception:
        return 0
    path = options.get("executablePath")
    if path and not os.path.exists(path):
        print(path)
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command, args = argv[1], argv[2:]
    if command == "qualified-names":
        return qualified_names()
    if command == "fingerprint":
        return fingerprint(args)
    if command == "secret":
        return secret()
    if command == "signed-in-users":
        return signed_in_users()
    if command == "recent-refusal":
        return recent_refusal(int(args[0]) if args else 120)
    if command == "deployment-age" and len(args) == 2:
        return deployment_age(*args)
    if command == "runtime-age" and len(args) == 2:
        return runtime_age(*args)
    if command == "missing-browser" and len(args) == 1:
        return missing_browser(args[0])
    print("unknown or incomplete command: %s" % " ".join(argv[1:]), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
