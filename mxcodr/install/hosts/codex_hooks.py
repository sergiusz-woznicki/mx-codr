# install/hosts/codex_hooks.py -- Merge the harness hooks into .codex/hooks.json.
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

settings.setdefault("description", "Mendix MDL skills and delivery gates")
hooks = settings.setdefault("hooks", {})
# A project-relative path, like Claude's and Cursor's. The `$(git rev-parse ...)`
# this used to embed only expands if the host runs hook commands through a POSIX
# shell -- under a native Windows Codex it is literal text. All three scripts
# resolve the repo root themselves anyway.
root = 'tools/mdl-checks/hooks'
wanted = {
    "UserPromptSubmit": {
        "hooks": [{
            "type": "command",
            "command": 'bash %s/remind-skills-codex.sh' % root,
            "timeout": 60,
        }],
    },
    # Codex hooks only its shell tool; apply_patch edits are not seen (the gate's drift check is).
    "PreToolUse": {
        "matcher": "^Bash$",
        "hooks": [{
            "type": "command",
            "command": 'bash %s/guard-harness-env.sh' % root,
            "timeout": 30,
        }],
    },
    "PostToolUse": {
        "matcher": "^Bash$",
        "hooks": [{
            "type": "command",
            "command": 'bash %s/after-mxcli-exec-codex.sh' % root,
            "timeout": 120,
        }],
    },
    "Stop": {
        "hooks": [{
            "type": "command",
            "command": 'bash %s/stop-gate-codex.sh' % root,
            "timeout": 600,
        }],
    },
}
for event, entry in wanted.items():
    existing = hooks.setdefault(event, [])
    # An earlier install registered the same script through an embedded
    # `$(git rev-parse ...)`. Drop any registration of this script before adding the
    # new one, so an upgrade replaces it instead of firing the hook twice.
    script = entry["hooks"][0]["command"].rsplit("/", 1)[-1].rstrip('"')
    existing[:] = [
        candidate for candidate in existing
        if not any(
            str(handler.get("command", "")).rstrip('"').endswith(script)
            for handler in candidate.get("hooks", [])
        )
    ]
    existing.append(entry)

with open(path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
