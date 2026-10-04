#!/usr/bin/env python3
"""Check flow MDL against the naming-and-captions rules (captions, variable names, positions).

Input: .mdl files or directories (searched recursively), normally the `describe` dump from tests/gate.sh.
Usage: check_mdl.py <file.mdl|dir> ... --skill naming [--captions error|warn] [--json]
--json keys: verdict, warnings, skills, sources, lines, failures.
Exit: 0 no failures (warnings allowed), 1 failures or no MDL found, 2 bad arguments.
"""

# Rule codes (FAIL counts against the run, WARN does not):
#   decision-caption             FAIL  if/case without @caption
#   caption-restates-expression  FAIL  decision caption contains $, <, >, != or " = "
#   caption-not-a-question       FAIL  decision caption does not end in "?"
#   case-caption-dropped         WARN  case caption equals its expression (mxcli overwrote it)
#   caption-on-loop              FAIL  loop/while with @caption (dropped: MDL042 on a loop, silently on a while)
#   loop-annotation              FAIL  loop/while without @annotation
#   action-caption               FAIL  retrieve/create/change/commit/delete/set/show page/call without @caption
#   action-caption-is-default    FAIL  caption is the Mendix default ("Retrieve Invoice", "Commit object")
#   placeholder-variable         FAIL  $Int1, $List2, $tmp, $x ...
#   type-echo-variable           FAIL  name ends in _List, _Object or _Obj
#   REFRESH01                    FAIL  a microflow that closes its page commits without `refresh`
#   PERF02 PERF03 PERF05 PERF06  WARN  a loop that only sums a retrieved list; a database call per row
#                                      in such a loop; a whole table filtered by an `if`; a loop that
#                                      only keeps the largest value (perf_rules.py)
#   PERF07                       WARN  with --entities: a query (retrieve, page source, grid filter)
#                                      no index serves (index_rules.py)
#   PERF08                       WARN  with --entities: an index no query in the model needs
# --captions warn turns the caption rules (CAPTION_RULES) into warnings: the gate passes it by
# default, since 286 of them landed at once on a session with no test green yet.

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from perf_rules import perf_findings  # noqa: E402
from index_rules import index_findings, redundant_findings  # noqa: E402

# Any `@word rest`; group 1 is the word (caption, annotation, position).
ANNOTATION_RE = re.compile(r"^\s*@(\w+)\s*(.*)$")
CAPTION_RE = re.compile(r"^\s*@caption\s+'(.*)'\s*$", re.IGNORECASE)
DECISION_RE = re.compile(r"^\s*(if|case)\b", re.IGNORECASE)
# A `while` is a loop, not a decision: mxcli writes no caption for it -- `@caption` passes
# `check` and `exec` and is gone from `describe`, with no MDL042 to say so -- while
# `@annotation` survives. Treated as a decision, it failed decision-caption with no way to pass:
# a Pi session spent 45 minutes on three such findings.
LOOP_RE = re.compile(r"^\s*(loop|while)\b", re.IGNORECASE)
# Activity lines; `create` needs a qualified entity so `create microflow` is not matched.
ACTION_RE = re.compile(
    r"^\s*(?:"
    r"retrieve\b|"
    r"change\s+\$|"
    r"commit\s+\$|"
    r"delete\s+\$|"
    r"(?:\$\w+\s*=\s*)?create\s+\w+\.|"
    r"show\s+page\b|"
    r"set\s+\$|"
    r"(?:\$\w+\s*=\s*)?call\s+(?:microflow|nanoflow)\b"
    r")",
    re.IGNORECASE,
)
# Mendix default captions: verb + one name ("Retrieve Invoice") or a fixed phrase ("Commit object").
DEFAULT_ACTION_CAPTION_RE = re.compile(
    r"^(?:"
    r"(?:Retrieve|Change|Commit|Delete|Create)\s+[A-Z][\w.]*|"
    r"Change variable|"
    r"Commit object|"
    r"Delete object|"
    r"Show page(?:\s+\S+)?|"
    r"Call (?:microflow|nanoflow)(?:\s+\S+)?"
    r")$",
    re.IGNORECASE,
)
# `create [or modify|replace] microflow|nanoflow Mod.Name`; group 1 is the name.
# Type word plus digits: $Int1, $List2, $Var10.
PLACEHOLDER_VAR_RE = re.compile(
    r"\$(?:int|bool|boolean|str|string|dec|decimal|date|datetime|list|obj|object|var|num|item)\d+\b",
    re.IGNORECASE,
)
THROWAWAY_VAR_RE = re.compile(r"\$(?:tmp|temp|foo|bar|x|y|z|aa)\b", re.IGNORECASE)
TYPE_ECHO_VAR_RE = re.compile(r"\$\w+_(?:list|object|obj)\b", re.IGNORECASE)
# A comparison in a caption: <, >, <=, >=, != or " = ".
COMPARISON_RE = re.compile(r"[<>]=?|!=|\s=\s")

# (regex, rule code, message label) for variable names.
VARIABLE_RULES = (
    (PLACEHOLDER_VAR_RE, "placeholder-variable", "placeholder variable name -- name what it holds, e.g. $OpenInvoiceCount"),
    (THROWAWAY_VAR_RE, "placeholder-variable", "throwaway variable name -- name what it holds, e.g. $DueDate"),
    (TYPE_ECHO_VAR_RE, "type-echo-variable", "variable name only restates its type -- name what it holds, e.g. $OverdueInvoices"),
)


class Failure(dict):
    def __init__(self, check: str, message: str, line: int | None = None):
        super().__init__(check=check, message=message, line=line)


class Warning_(dict):
    """A finding reported that does not fail the run (one the author cannot fix, or a demoted caption rule)."""

    def __init__(self, check: str, message: str, line: int | None = None):
        super().__init__(check=check, message=message, line=line)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    # Authored scripts quote identifiers, describe output does not; MDL strings use single quotes.
    text = text.replace('"', "")
    kept = [line for line in text.splitlines() if not line.lstrip().startswith("--")]
    return "\n".join(kept)


def preceding_annotations(lines: list[str], index: int) -> list[tuple[str, str]]:
    """(kind, raw line) of the @-annotations directly above lines[index]."""
    found = []
    cursor = index - 1
    while cursor >= 0:
        line = lines[cursor]
        if not line.strip():
            cursor -= 1
            continue
        match = ANNOTATION_RE.match(line)
        if not match:
            break
        found.append((match.group(1).lower(), line))
        cursor -= 1
    return found


def caption_text(annotation_lines: list[tuple[str, str]]) -> str:
    """Text of the parsable @caption, else ""."""
    for kind, raw in annotation_lines:
        if kind == "caption":
            match = CAPTION_RE.match(raw)
            if match:
                return match.group(1)
    return ""  # no @caption, or one that does not parse


def annotation_kinds(annotations: list[tuple[str, str]]) -> list[str]:
    return [kind for kind, _ in annotations]


def decision_findings(lines: list[str], index: int) -> tuple[list[Failure], list[Warning_], bool]:
    """Caption rules for an if/case/while; the bool is False when it has no @caption."""
    line = lines[index]
    annotations = preceding_annotations(lines, index)
    if "caption" not in annotation_kinds(annotations):
        failure = Failure(
            "decision-caption",
            f"decision without @caption -- put @caption '<the question it answers?>' on the line above: {line.strip()[:70]}",
            index + 1,
        )
        return [failure], [], False

    text = caption_text(annotations)
    if not text:
        return [], [], True
    expression = line.strip()[len(line.strip().split()[0]):].strip()
    is_enum_split = line.strip().lower().startswith("case")
    if is_enum_split and text.strip() == expression:
        # mxcli overwrites an enum case's @caption with its expression.
        warning = Warning_(
            "case-caption-dropped",
            "mxcli wrote this split's own expression as its caption "
            f"('{text}'); measured on 11.13.0 it discards both @caption "
            "and @annotation on a split, so this is not the author's doing",
            index + 1,
        )
        return [], [warning], True
    if "$" in text or COMPARISON_RE.search(text):
        failure = Failure(
            "caption-restates-expression",
            f"caption restates the expression: '{text}' -- write the business question instead, with no $, <, >, != or =, ending in '?'",
            index + 1,
        )
        return [failure], [], True
    if not text.rstrip().endswith("?"):
        failure = Failure(
            "caption-not-a-question",
            f"decision caption is not phrased as a question: '{text}' -- end it with '?', e.g. 'Is the invoice overdue?'",
            index + 1,
        )
        return [failure], [], True
    return [], [], True


def loop_findings(lines: list[str], index: int) -> list[Failure]:
    """A loop or while loop needs @annotation and must not carry @caption."""
    line = lines[index]
    kinds = annotation_kinds(preceding_annotations(lines, index))
    failures = []
    if "caption" in kinds:
        failures.append(
            Failure(
                "caption-on-loop",
                "loop carries @caption, which is dropped (MDL042 on a loop, silently on a while) -- write @annotation '<why it repeats>' above it instead",
                index + 1,
            )
        )
    if "annotation" not in kinds:
        failures.append(
            Failure(
                "loop-annotation",
                f"loop without @annotation -- put @annotation '<why it repeats>' on the line above: {line.strip()[:70]}",
                index + 1,
            )
        )
    return failures


def action_findings(lines: list[str], index: int) -> list[Failure]:
    """An action needs a @caption that is not the Mendix default."""
    line = lines[index]
    annotations = preceding_annotations(lines, index)
    if "caption" not in annotation_kinds(annotations):
        return [
            Failure(
                "action-caption",
                f"action without business-operation @caption -- put @caption '<what it does for the business>' on the line above: {line.strip()[:70]}",
                index + 1,
            )
        ]
    text = caption_text(annotations)
    if text and DEFAULT_ACTION_CAPTION_RE.match(text.strip()):
        return [
            Failure(
                "action-caption-is-default",
                f"action caption restates the Mendix default: '{text}' -- say what it does for the business, e.g. 'Load the open invoices'",
                index + 1,
            )
        ]
    return []


def variable_findings(line: str, line_number: int) -> list[Failure]:
    failures = []
    for regex, check, label in VARIABLE_RULES:
        for hit in regex.findall(line):
            what, _, fix = label.partition(" -- ")
            failures.append(Failure(check, f"{what}: {hit}" + (f" -- {fix}" if fix else ""), line_number))
    return failures


def check_naming(lines: list[str]) -> tuple[list[Failure], list[Warning_]]:
    """Return (failures, warnings) for all naming rules."""
    failures: list[Failure] = []
    warnings: list[Warning_] = []

    for index, line in enumerate(lines):
        line_number = index + 1
        stripped = line.strip().lower()
        if stripped.startswith("end ") or stripped == "end":
            continue

        if DECISION_RE.match(line):
            found, warned, has_caption = decision_findings(lines, index)
            failures.extend(found)
            warnings.extend(warned)
            if not has_caption:
                continue  # skips the variable-name rules for this line
        elif LOOP_RE.match(line):
            failures.extend(loop_findings(lines, index))
        elif ACTION_RE.match(line):
            failures.extend(action_findings(lines, index))

        failures.extend(variable_findings(line, line_number))

    return failures, warnings


# A microflow behind a popup's Save: it commits, then `close page`. Without `refresh` the
# client is never told the object changed, so the grid under the popup still shows the old
# rows until a reload -- in every app the harness built (new invoice, new customer). The tests
# missed it: a session reloaded the page in its test (`reopen_app()`) to see the new row.
MICROFLOW_START_RE = re.compile(r"^create\s+(?:or\s+(?:modify|replace)\s+)?microflow\s+([\w.]+)", re.IGNORECASE)
COMMIT_STATEMENT_RE = re.compile(r"^\s*(?:commit\s+\$\w+|change\s+\$\w+\b.*\bcommit\b)", re.IGNORECASE | re.DOTALL)


def refresh_findings(lines: list[str]) -> list[Failure]:
    """REFRESH01: in a microflow that ends in `close page`, every commit carries `refresh`."""
    failures: list[Failure] = []
    name, statements, closes = None, [], False

    def flush() -> None:
        if not name or not closes:
            return
        for line_number, statement in statements:
            if COMMIT_STATEMENT_RE.match(statement) and not re.search(r"\brefresh\b", statement, re.IGNORECASE):
                target = re.search(r"\$\w+", statement).group(0)
                failures.append(Failure(
                    "REFRESH01",
                    f"{name} closes its page but commits {target} without refresh -- the grid under the "
                    f"popup keeps showing the old rows until a reload: write `commit {target} refresh;` "
                    f"(or `change {target} (...) commit refresh;`)",
                    line_number))

    current, start, in_body = "", None, False
    for index, line in enumerate(lines):
        match = MICROFLOW_START_RE.match(line)
        if match:
            flush()
            name, statements, closes, current, start, in_body = match.group(1), [], False, "", None, False
            continue
        if name is None or ANNOTATION_RE.match(line):
            continue
        if not in_body:
            # the signature and its parameters end at `begin`
            in_body = bool(re.match(r"^\s*begin\s*$", line, re.IGNORECASE))
            continue
        if re.match(r"^end;\s*$", line):
            flush()
            name = None
            continue
        if not current.strip():
            start = index + 1
        current += " " + line.strip()
        if line.rstrip().endswith(";"):
            statement = current.strip()
            if re.match(r"close\s+page\b", statement, re.IGNORECASE):
                closes = True
            statements.append((start, statement))
            current = ""
    flush()
    return failures


def check_naming_and_refresh(lines: list[str]) -> tuple[list[Failure], list[Warning_]]:
    failures, warnings = check_naming(lines)
    # Performance (PERF02/03/05/06, perf_rules.py): warnings, listed before the caption warnings.
    perf = [Warning_(code, message, line) for code, message, line in perf_findings(lines)]
    return failures + refresh_findings(lines), perf + warnings


CHECKS = {"naming": check_naming_and_refresh}

# The wording rules: a flow runs the same without them. Variable names and loop captions that
# mxcli drops stay failures.
CAPTION_RULES = {"decision-caption", "caption-restates-expression", "caption-not-a-question",
                 "loop-annotation", "action-caption", "action-caption-is-default"}


FLOW_START = re.compile(r"^\s*create\s+(?:or\s+(?:modify|replace)\s+)?(?:microflow|nanoflow)\s+(?P<name>[\w.]+)", re.I)
LAYOUT_ONLY = re.compile(r"^\s*@(?:position|anchor|merge)\b", re.I)


def flow_blocks(lines: list[str]) -> list[tuple[str, int, int]]:
    """(flow, first line, last line), 1-based, for every microflow and nanoflow in the dump."""
    starts = [(i + 1, m.group("name")) for i, line in enumerate(lines) if (m := FLOW_START.match(line))]
    return [(name, start, (starts[k + 1][0] - 1) if k + 1 < len(starts) else len(lines))
            for k, (start, name) in enumerate(starts)]


def flow_hashes(lines: list[str]) -> dict[str, str]:
    """{flow: hash of its text}; where its boxes sit on the canvas does not count."""
    return {name: hashlib.sha256("\n".join(l for l in lines[start - 1:end] if not LAYOUT_ONLY.match(l))
                                 .encode()).hexdigest()[:16]
            for name, start, end in flow_blocks(lines)}


def collect_text(sources: list[Path]) -> tuple[str, list[Path]]:
    """Joined text of every .mdl under sources, and the files read; missing paths are skipped."""
    chunks, used = [], []
    for source in sources:
        if source.is_dir():
            files = sorted(source.rglob("*.mdl"))
        else:
            files = [source] if source.exists() else []
        for file in files:
            chunks.append(file.read_text(encoding="utf-8", errors="replace"))
            used.append(file)
    return "\n".join(chunks), used


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="+", type=Path, help="MDL files or directories")
    parser.add_argument(
        "--skill",
        action="append",
        choices=sorted(CHECKS),
        required=True,
        help="which skill's rules to enforce (repeatable)",
    )
    parser.add_argument("--captions", choices=("error", "warn"), default="error",
                        help="warn: caption rules are warnings, not failures")
    parser.add_argument("--entities", type=Path,
                        help="DESCRIBE ENTITY output (file or directory): adds PERF07, an attribute "
                             "filtered or sorted on with no index")
    parser.add_argument("--pages", type=Path, help="DESCRIBE PAGE output, read for PERF07 data sources")
    parser.add_argument("--flow-hashes", type=Path,
                        help="write {flow: hash of its text} here (the gate keeps the one of each DONE)")
    parser.add_argument("--captions-baseline", type=Path,
                        help="with --captions warn: caption findings in a flow that is new or changed "
                             "since this baseline stay failures")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    text, used = collect_text(args.sources)
    if not text.strip():
        print(f"FAIL  no MDL found in {[str(s) for s in args.sources]}", file=sys.stderr)
        return 1

    lines = strip_comments(text).splitlines()

    failures: list[Failure] = []
    warnings: list[Warning_] = []
    for skill in args.skill:
        skill_failures, skill_warnings = CHECKS[skill](lines)
        failures.extend(skill_failures)
        warnings.extend(skill_warnings)
    if args.entities and "naming" in args.skill:
        entity_text, _ = collect_text([args.entities])
        page_text, _ = collect_text([args.pages]) if args.pages else ("", [])
        documents = lines + strip_comments(page_text).splitlines()
        indexes = [Warning_(code, message, line) for code, message, line in
                   index_findings(entity_text.splitlines(), documents) + redundant_findings(entity_text.splitlines(), documents)]
        perf = [w for w in warnings if w["check"].startswith("PERF")]
        warnings = perf + indexes + [w for w in warnings if not w["check"].startswith("PERF")]
    hashes = flow_hashes(lines)
    if args.flow_hashes:
        args.flow_hashes.write_text(json.dumps(hashes, indent=0, sort_keys=True))
    # After the first DONE (the gate passes the hashes it kept then), a microflow that is new or
    # changed since the last DONE needs its captions; older ones keep them as warnings, a backlog.
    fresh: set[str] = set()
    if args.captions_baseline and args.captions_baseline.is_file():
        try:
            baseline = json.loads(args.captions_baseline.read_text())
        except (OSError, ValueError):
            baseline = {}
        fresh = {name for name, digest in hashes.items() if baseline.get(name) != digest}
    blocks = flow_blocks(lines)

    def flow_at(line: int) -> str:
        return next((name for name, start, end in blocks if start <= (line or 0) <= end), "")

    caption_warnings = 0
    if args.captions == "warn":
        for failure in failures:
            if failure["check"] in CAPTION_RULES and flow_at(failure["line"]) in fresh:
                failure["message"] += (f" -- {flow_at(failure['line'])} is new or changed since the last DONE, "
                                       f"so its captions are required now")
        demoted = [f for f in failures if f["check"] in CAPTION_RULES and flow_at(f["line"]) not in fresh]
        failures = [f for f in failures if not (f["check"] in CAPTION_RULES and flow_at(f["line"]) not in fresh)]
        warnings.extend(Warning_(f["check"], f["message"], f["line"]) for f in demoted)
        caption_warnings = len(demoted)

    report = {
        "verdict": "PASS" if not failures else "FAIL",
        "warnings": warnings,
        "skills": args.skill,
        "sources": [str(path) for path in used],
        "lines": len(lines),
        "failures": failures,
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        perf = sum(1 for w in warnings if w["check"].startswith("PERF"))
        extra = (f", {perf} performance warning(s)" if perf else "") + (
            f", {caption_warnings} caption warning(s)" if caption_warnings else "")
        print(f"{report['verdict']}  {len(failures)} failure(s) over {len(lines)} lines{extra}")
        for failure in failures:
            location = f"line {failure['line']}" if failure["line"] else "-"
            print(f"  - [{failure['check']}] {location}: {failure['message']}")
        for warning in warnings:
            location = f"line {warning['line']}" if warning["line"] else "-"
            print(f"  ! [{warning['check']}] {location}: {warning['message']}")

    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
