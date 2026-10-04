# install/hosts/claude_settings.py -- Merge the harness hooks into .claude/settings.local.json.
# Run by install/step_hosts.sh with the file's path; the code is what that step held inline.
import json, sys
path = sys.argv[1]
try:
    settings = json.load(open(path))
except FileNotFoundError:
    settings = {}
except json.JSONDecodeError as exc:
    # Replacing it would throw away whatever the developer had; the Codex and Cursor
    # mergers below refuse for the same reason.
    raise SystemExit("   !! %s is not valid JSON (%s); leaving it alone. Fix it and re-run." % (path, exc))
hooks = settings.setdefault("hooks", {})
wanted = [
    ("UserPromptSubmit", {"hooks": [{"type": "command", "command": "bash tools/mdl-checks/hooks/remind-skills.sh"}]}),
    # 180s: the precheck copies the model and runs mx check on it (~6s on a small app).
    ("PreToolUse", {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash tools/mdl-checks/hooks/before-mxcli-exec.sh", "timeout": 180}]}),
    # tests/harness.env is the person's: the session may not flip a gate switch.
    ("PreToolUse", {"matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit", "hooks": [{"type": "command", "command": "bash tools/mdl-checks/hooks/guard-harness-env.sh", "timeout": 30}]}),
    ("PostToolUse", {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash tools/mdl-checks/hooks/after-mxcli-exec.sh"}]}),
]
for event, entry in wanted:
    existing = hooks.setdefault(event, [])
    if not any(json.dumps(e, sort_keys=True) == json.dumps(entry, sort_keys=True) for e in existing):
        existing.append(entry)
json.dump(settings, open(path, "w"), indent=2)
