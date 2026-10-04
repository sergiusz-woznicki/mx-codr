# install/hosts/cursor_hooks.py -- Merge the harness hooks into .cursor/hooks.json.
# Run by install/step_hosts.sh with the file's path; the code is what that step held inline.
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path) as handle:
            settings = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SystemExit("invalid existing %s: %s" % (path, exc))
else:
    settings = {}

settings.setdefault("version", 1)
hooks = settings.setdefault("hooks", {})
# `bash <path>`, not `./<path>`: on Windows a .sh file is not executable, and the
# shebang means nothing to the shell Cursor spawns.
root = "tools/mdl-checks/hooks"
wanted = {
    "sessionStart": {"command": "bash %s/remind-skills-cursor.sh" % root, "timeout": 30},
    # Before an `mxcli exec`: mx check on a copy of the model, denying an exec that would break the build.
    "beforeShellExecution": {"command": "bash %s/before-mxcli-exec-cursor.sh" % root, "timeout": 180},
    "postToolUse": {"command": "bash %s/after-mxcli-exec-cursor.sh" % root, "timeout": 120},
    # loop_limit caps the auto-submitted follow-ups; the marker is cleared on green,
    # so a session that fixes its failures stops looping before reaching it.
    "stop": {"command": "bash %s/stop-gate-cursor.sh" % root, "timeout": 600, "loop_limit": 5},
}
for event, entry in wanted.items():
    existing = hooks.setdefault(event, [])
    # An earlier install registered the same script as `./tools/...`, which does not
    # run on Windows. Drop any registration of this script before adding the new one,
    # so the upgrade replaces it instead of firing the hook twice.
    script = entry["command"].rsplit("/", 1)[-1]
    existing[:] = [
        candidate for candidate in existing
        if not str(candidate.get("command", "")).endswith(script)
    ]
    existing.append(entry)

with open(path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
