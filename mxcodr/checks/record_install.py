"""Record what the installer put in this project, and what each file looked like.

Two kinds of drift have each cost a day, and neither announced itself. A project
ran checkers from 2026.09.09 against a bundle at 2026.09.11 and reported
`naming: PASS` where the current checker finds 37 problems -- a gate that passes
because it is out of date is worse than no gate, because the green is still
printed. Separately, files hand-copied into a live project, some of them but not
all, left gate.sh current and check_mdl.py two versions behind while the VERSION
stamp claimed both were new.

So install.sh writes tools/mdl-checks/INSTALL.json here: the bundle version, the
date, and a sha256 per installed file. tests/portable.sh compares against it at
every gate preflight.

    python3 record_install.py <app-dir> <bundle-dir> <version>

The file list comes from the bundle, never from a glob over the app: an installed
Mendix project also holds ~50 mxcli skills and 27 mxcli lint rules in the same
directories, and tracking those would report every mxcli upgrade as harness drift.

Run it by hand after copying harness files into a project without going through
install.sh, so the baseline matches what is actually on disk:

    python3 tools/mdl-checks/record_install.py . mxcodr "$(cat mxcodr/VERSION)"
"""

import hashlib
import json
import os
import sys
import time

# Bundle path -> where install.sh puts it. A file the installer only writes when
# absent (run-app.sh, the example tests) belongs to the project once it is there,
# and is deliberately not tracked.
SKILL_DIRS = (".claude/skills", ".agents/skills", ".ai-context/skills")
HARNESS_SCRIPTS = ("gate.sh", "orient.sh", "diagnose.sh", "lib.sh", "portable.sh")


def listdir(path, suffix):
    try:
        return sorted(n for n in os.listdir(path) if n.endswith(suffix))
    except OSError:
        return []


def destinations(src):
    """Yield (bundle file, app-relative destination) for everything tracked."""
    for name in HARNESS_SCRIPTS:
        yield os.path.join(src, "tests", name), "tests/" + name

    for name in listdir(os.path.join(src, "checks"), ".py"):
        yield os.path.join(src, "checks", name), "tools/mdl-checks/" + name

    for name in listdir(os.path.join(src, "hooks"), ".sh"):
        yield os.path.join(src, "hooks", name), "tools/mdl-checks/hooks/" + name

    for name in listdir(os.path.join(src, "lint-rules"), ".star"):
        yield os.path.join(src, "lint-rules", name), ".claude/lint-rules/" + name

    for name in listdir(os.path.join(src, "plugins"), ".js"):
        yield os.path.join(src, "plugins", name), ".opencode/plugin/" + name

    yield os.path.join(src, "rules", "mdl-skills.md"), ".claude/rules/mdl-skills.md"
    yield os.path.join(src, "rules", "mdl-skills.mdc"), ".cursor/rules/mdl-skills.mdc"

    skills_root = os.path.join(src, "skills")
    try:
        skills = sorted(os.listdir(skills_root))
    except OSError:
        skills = []
    for skill in skills:
        source = os.path.join(skills_root, skill, "SKILL.md")
        if not os.path.isfile(source):
            continue
        for skill_dir in SKILL_DIRS:
            yield source, "%s/%s/SKILL.md" % (skill_dir, skill)


def main(argv):
    if len(argv) != 4:
        raise SystemExit(__doc__.strip().splitlines()[0])
    app, src, version = argv[1], argv[2], argv[3]

    files = {}
    for source, relative in destinations(src):
        if not os.path.isfile(source):
            continue
        # Keys stay forward-slashed so a manifest written on Windows still reads
        # on a Mac, and the other way round.
        path = os.path.join(app, *relative.split("/"))
        try:
            with open(path, "rb") as handle:
                files[relative] = hashlib.sha256(handle.read()).hexdigest()
        except OSError:
            # Not installed in this project -- a host whose directory is absent,
            # for instance. Nothing to compare, so nothing to record.
            continue

    manifest = os.path.join(app, "tools", "mdl-checks", "INSTALL.json")
    os.makedirs(os.path.dirname(manifest), exist_ok=True)
    with open(manifest, "w", encoding="utf-8") as out:
        json.dump({"version": version,
                   "installed": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "files": files},
                  out, indent=1, sort_keys=True)
        out.write("\n")
    print(len(files))


if __name__ == "__main__":
    main(sys.argv)
