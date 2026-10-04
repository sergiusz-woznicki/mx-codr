# install/hosts/opencode_config.py -- List the harness instruction files in opencode.json.
# Run by install/step_hosts.sh with the file's path; the code is what that step held inline.
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path) as handle:
            config = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SystemExit("invalid existing %s: %s" % (path, exc))
else:
    config = {}

config.setdefault("$schema", "https://opencode.ai/config.json")
instructions = config.setdefault("instructions", [])
for entry in (".claude/rules/mdl-skills.md", "tools/mdl-checks/syntax-digest.md"):
    if entry not in instructions:
        instructions.append(entry)

with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
