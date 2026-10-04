# install/hosts/codex_config.py -- Add the hook-trust reminder to .codex/config.toml; prints what it did.
# Run by install/step_hosts.sh with the file's path; the code is what that step held inline.
import os, re, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        existing = handle.read()
except FileNotFoundError:
    existing = ""

if re.search(r"(?m)^[ \t]*developer_instructions[ \t]*=", existing):
    print("existing")
    raise SystemExit(0)

reminder = '''# Codex hook trust reminder
developer_instructions = """
After the first user prompt in each new Codex session for this repository, include one short reminder to open `/hooks` and review or trust the project hooks if they are new or changed. Do not repeat the reminder later in the same session.
"""

'''
with open(path, "w", encoding="utf-8") as handle:
    handle.write(reminder)
    handle.write(existing)
print("added")
