"""The decision of hooks/guard-harness-env.sh: may this tool call run?

    <tool call as JSON on stdin> | python3 guard_harness.py

Prints `<kind>\t<path or detail>` when the call is blocked (kind: env, harness, switch, token,
outside) and nothing when it may run; the hook turns the kind into its message. Exit 0 always.
It lived inside the hook as 227 lines of Python in a shell string, where nothing could import
and test it; the text below is that code unchanged (audit of 2026-10-04).
"""
import json, os, re, shlex, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = str(data.get("tool_name") or "").lower()
args = data.get("tool_input") or {}
root = os.getcwd().replace("\\", "/").rstrip("/")
ENV = "tests/harness.env"
DIRS = ["tools/mdl-checks/", "tests/gate/", "tests/lib/", ".claude/lint-rules/", ".pi/extensions/",
        ".opencode/plugin/"]
FILES = {".claude/settings.local.json", ".codex/hooks.json", ".cursor/hooks.json", "tests/gate.sh",
         "tests/lib.sh", "tests/precheck.sh", "tests/portable.sh", "tests/orient.sh",
         "tests/diagnose.sh", "tests/peek.sh", "tests/run-app.sh", "tests/run-docker.sh",
         "tests/scenario-helpers.js", "tests/marketplace-login.sh", ".mxcli/marketplace-login-needed"}
try:
    recorded = json.load(open("tools/mdl-checks/INSTALL.json")).get("files") or {}
    FILES |= {f for f in recorded if f.startswith("tests/") and not f.startswith("tests/verify-")}
except Exception:
    pass
allow_edits = False
try:
    allow_edits = bool(re.search(r"^\s*MDL_HARNESS_EDITS\s*=\s*[\x22\x27]?allow", open(ENV).read(), re.M))
except Exception:
    pass

def rel(path):
    path = path.strip().strip("\x22\x27").replace("\\", "/")
    if path.lower().startswith(root.lower() + "/"):
        path = path[len(root) + 1:]
    while path.startswith("./"):
        path = path[2:]
    return path

def kind(path):
    p = rel(path)
    low = p.lower()
    if low == ENV or low.endswith("/" + ENV):
        return "env"
    if allow_edits:
        return None
    for f in FILES:
        if p == f or p.endswith("/" + f):
            return "harness"
    for d in DIRS:
        if p.startswith(d) or ("/" + d) in p:
            return "harness"
    return None

def shell_targets(command):
    """Paths a shell command writes: redirect targets, and the written operands of write verbs.
    Four ways around it were found in the audit of 2026-10-04 and are read now: a `cd` before the
    write (`cd tests && echo x > harness.env`), a link to a guarded file (`ln -s tests/harness.env
    x`, then write x), a copy into a directory (`cp x tests/`), and a write from inline code
    (`python3 -c`, `node -e`) that names harness.env."""
    targets = []
    here = ""                       # where a `cd` earlier in the command left the shell, under the project

    def placed(path):
        path = path.strip().strip("\x22\x27")
        if not here or path.startswith(("/", "~", "$")) or re.match(r"^[A-Za-z]:", path):
            return path
        return os.path.normpath(here + "/" + path).replace("\\", "/")

    for segment in re.split(r"&&|\|\||[;|\n]", command):
        targets += [placed(t) for t in re.findall(r">>?\s*([^\s;&|<>]+)", segment)]
        try:
            words = shlex.split(segment)
        except ValueError:
            words = segment.split()
        words = [w for w in words if w not in (">", ">>")]
        if not words:
            continue
        verb = os.path.basename(words[0])
        operands = [w for w in words[1:] if not w.startswith("-")]
        if verb == "cd" and len(operands) == 1:
            here = rel(placed(operands[0]))
        elif verb == "tee" or verb in ("rm", "truncate", "shred", "unlink"):
            targets += [placed(o) for o in operands]
        elif verb in ("sed", "perl") and any(w.startswith("-i") or w == "--in-place" for w in words[1:]):
            targets += [placed(o) for o in operands]
        elif verb == "ln" and operands:
            targets += [placed(o) for o in operands]          # a link to it is a way to write it
        elif verb in ("cp", "mv", "install", "rsync") and operands:
            destination = placed(operands[-1])
            targets.append(destination)
            if destination.endswith("/") or os.path.isdir(destination):
                targets += [destination.rstrip("/") + "/" + os.path.basename(o.rstrip("/")) for o in operands[:-1]]
        elif verb == "dd":
            targets += [placed(w[3:]) for w in words if w.startswith("of=")]
        elif re.match(r"^(python[\d.]*|node|ruby|perl|php)$", verb) and any(w in ("-c", "-e") for w in words[1:]):
            code = " ".join(words[1:])
            if "harness.env" in code and re.search(r"write|open\s*\([^)]*[\x22\x27][wa]|>", code):
                targets.append(ENV)
    return targets

HOME = os.path.expanduser("~").replace("\\", "/").rstrip("/")
READ_ROOTS = ("/System", "/Applications", "/Library", "/usr", "/opt", HOME + "/.mxcli/mxbuild", HOME + "/.mxcli/runtime")
SEARCH_VERBS = ("find", "rg", "ag", "fd", "fdfind", "mdfind", "locate")
READ_VERBS = ("cat", "sed", "head", "tail", "less", "more", "strings", "awk", "bat")

def expand(path):
    path = path.strip().strip("\x22\x27").replace("\\", "/")
    if path == "~" or path.startswith("~/"):
        path = HOME + path[1:]
    path = path.replace("$HOME", HOME).replace("${HOME}", HOME)
    return path

def outside(path):
    """An absolute path not under the project, or a relative one that climbs out of it."""
    p = expand(path)
    if p.startswith("/dev/"):
        return False
    if p.startswith("/") or re.match(r"^[A-Za-z]:/", p):
        return not (p.lower() == root.lower() or p.lower().startswith(root.lower() + "/"))
    return p == ".." or p.startswith("../")

def tmp_checkout(path):
    """A file inside a source checkout that sits under /tmp (a directory with .git, go.mod or
    package.json between /tmp and the file): the mxcli sources a session read for a widget."""
    p = expand(path)
    m = re.match(r"^(/private/tmp|/tmp|/System/Volumes/Data/private/tmp)/(.+)$", p)
    if not m:
        return False
    base, rest = m.group(1), m.group(2).split("/")
    for depth in range(1, len(rest)):
        folder = base + "/" + "/".join(rest[:depth])
        if any(os.path.exists(folder + "/" + marker) for marker in (".git", "go.mod", "package.json")):
            return True
    return False

def command_words(command):
    """The simple commands as word lists, split on ; && || | and newlines outside quotes. Splitting
    the raw text first cut a grep pattern such as \x27add \\$|remove \\$\x27 inside its quotes, and the
    half-quoted \\$ read as the absolute path /$ -- a false block."""
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars="();<>|&\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        out, cur = [], []
        for tok in lex:
            if tok and set(tok) <= set(";|&\n()"):
                if cur:
                    out.append(cur)
                cur = []
            else:
                cur.append(tok)
        if cur:
            out.append(cur)
        return out
    except ValueError:
        return [segment.split() for segment in re.split(r"&&|\|\||[;|\n]", command)]

def outside_target(command):
    """The first path a command searches or reads outside the project, or None."""
    for words in command_words(command):
        if not words:
            continue
        verb = os.path.basename(words[0])
        rest = words[1:]
        if verb in ("mdfind", "locate"):
            return verb
        if verb in SEARCH_VERBS:
            roots = []
            for w in rest:
                if w.startswith("-"):
                    if verb == "find":
                        break
                    continue
                roots.append(w)
            if verb != "find":
                roots = roots[1:]  # the first operand is the pattern
            for r in roots:
                if outside(r):
                    return r
        elif verb in ("grep", "egrep", "fgrep") and any(
                w in ("--recursive", "--dereference-recursive")
                or (w.startswith("-") and not w.startswith("--") and ("r" in w[1:] or "R" in w[1:])) for w in rest):
            operands = [w for w in rest if not w.startswith("-")]
            for r in operands[1:]:
                if outside(r):
                    return r
        elif verb in READ_VERBS:
            skip = False
            for w in rest:
                # `cat > /tmp/x` writes /tmp/x: a redirect target is not read.
                if w in (">", ">>", "<"):
                    skip = w != "<"
                    continue
                if skip or w.startswith(">") or w.startswith("-"):
                    skip = False
                    continue
                p = expand(w)
                if any(p == r or p.startswith(r + "/") for r in READ_ROOTS) or tmp_checkout(w):
                    return w
    return None

def token_read(command):
    """The Mendix token a command would show: ~/.mxcli/auth.json, $MENDIX_PAT, or the whole
    environment while MENDIX_PAT is set in it. mxcli reads the token itself; the session never
    needs its value, and anything it prints lands in the session log and at the model provider."""
    if re.search(r"\.mxcli[/\\\\]auth\.json", command):
        return "~/.mxcli/auth.json"
    if re.search(r"\$\{?MENDIX_PAT|printenv\s+MENDIX_PAT", command):
        return "MENDIX_PAT"
    if os.environ.get("MENDIX_PAT"):
        for words in command_words(command):
            if not words:
                continue
            verb, rest = os.path.basename(words[0]), words[1:]
            if verb in ("env", "printenv") and all(w.startswith("-") for w in rest):
                return "the environment (MENDIX_PAT is set)"
            if verb == "set" and not rest:
                return "the environment (MENDIX_PAT is set)"
            if verb in ("export", "declare") and rest and all(w in ("-p", "-x", "-px", "-xp") for w in rest):
                return "the environment (MENDIX_PAT is set)"
    return None

SWITCHES = ("MDL_REQUIRE_PRODUCTION", "MDL_ALLOW_GREEN_FIRST", "MDL_VISUAL", "MDL_VISUAL_REVIEW",
            "MDL_RUNTIME_ERRORS", "MDL_PRECHECK", "MDL_GATE_CACHE", "MDL_HARNESS_EDITS", "MDL_CAPTIONS",
            "MDL_SCOPE", "MDL_MARKETPLACE_LOGIN")
hit = None
if tool == "bash":
    command = str(args.get("command") or "")
    for target in shell_targets(command):
        k = kind(target)
        if k:
            hit = (k, rel(target))
            break
    if not hit and re.search(r"tests[/\\\\](gate|precheck)\.sh", command) and re.search(
            r"(^|[\s;&|(])(export\s+)?(%s)=" % "|".join(SWITCHES), command):
        hit = ("switch", "")
    if not hit:
        secret = token_read(command)
        if secret:
            hit = ("token", secret)
    if not hit:
        away = outside_target(command)
        if away:
            hit = ("outside", away)
elif tool in ("edit", "write", "multiedit", "notebookedit", "patch", "apply_patch"):
    path = str(args.get("file_path") or args.get("filePath") or args.get("notebook_path")
               or args.get("path") or "")
    k = kind(path) if path else None
    if k:
        hit = (k, rel(path))
if hit:
    print("%s\t%s" % hit)
