#!/usr/bin/env python3
"""Check flow MDL against the naming-and-captions rules (captions, variable names, positions).

Input: .mdl files or directories (searched recursively), normally the `describe` dump from tests/gate.sh.
Usage: check_mdl.py <file.mdl|dir> ... --skill naming [--json]
--json keys: verdict, warnings, skills, sources, lines, failures.
Exit: 0 no failures (warnings allowed), 1 failures or no MDL found, 2 bad arguments.
"""

# Rule codes (FAIL counts against the run, WARN does not):
#   decision-caption             FAIL  if/case/while without @caption
#   caption-restates-expression  FAIL  decision caption contains $, <, >, != or " = "
#   caption-not-a-question       FAIL  decision caption does not end in "?"
#   case-caption-dropped         WARN  case caption equals its expression (mxcli overwrote it)
#   caption-on-loop              FAIL  loop with @caption (Mendix drops it, MDL042)
#   loop-annotation              FAIL  loop without @annotation
#   action-caption               FAIL  retrieve/create/change/commit/delete/set/show page/call without @caption
#   action-caption-is-default    FAIL  caption is the Mendix default ("Retrieve Invoice", "Commit object")
#   placeholder-variable         FAIL  $Int1, $List2, $tmp, $x ...
#   type-echo-variable           FAIL  name ends in _List, _Object or _Obj
#   overlapping-position         FAIL  two activities at the same @position in one flow
#   loop-box-empty               FAIL  loop body fills under 8% of its box (FLOW02)
#   flow-width                   FAIL  @position x values span more than 1600px (FLOW01)

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Any `@word rest`; group 1 is the word (caption, annotation, position).
ANNOTATION_RE = re.compile(r"^\s*@(\w+)\s*(.*)$")
CAPTION_RE = re.compile(r"^\s*@caption\s+'(.*)'\s*$", re.IGNORECASE)
DECISION_RE = re.compile(r"^\s*(if|case|while)\b", re.IGNORECASE)
LOOP_RE = re.compile(r"^\s*loop\b", re.IGNORECASE)
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
POSITION_RE = re.compile(r"^\s*@position\s*\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)", re.IGNORECASE)
# `create [or modify|replace] microflow|nanoflow Mod.Name`; group 1 is the name.
MICROFLOW_START_RE = re.compile(
    r"^\s*create (?:or (?:modify|replace) )?(?:microflow|nanoflow)\s+([\w.]+)", re.IGNORECASE
)
# Type word plus digits: $Int1, $List2, $Var10.
PLACEHOLDER_VAR_RE = re.compile(
    r"\$(?:int|bool|boolean|str|string|dec|decimal|date|datetime|list|obj|object|var|num|item)\d+\b",
    re.IGNORECASE,
)
THROWAWAY_VAR_RE = re.compile(r"\$(?:tmp|temp|foo|bar|x|y|z|aa)\b", re.IGNORECASE)
TYPE_ECHO_VAR_RE = re.compile(r"\$\w+_(?:list|object|obj)\b", re.IGNORECASE)
# Unused.
MICROFLOW_HEAD_RE = re.compile(
    r"^\s*create (?:or (?:modify|replace) )?microflow\s+([\w.]+)", re.IGNORECASE
)


# Printed by main(); never affect the exit code.
WARNINGS: list = []


class Failure(dict):
    def __init__(self, check: str, message: str, line: int | None = None):
        super().__init__(check=check, message=message, line=line)


class Warning_(dict):
    """A finding the author cannot fix; reported but does not fail the run."""

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


def caption_text(annotation_lines: list[tuple[str, str]]) -> str | None:
    """Text of the parsable @caption, else "" (never None)."""
    for kind, raw in annotation_lines:
        if kind == "caption":
            match = CAPTION_RE.match(raw)
            if match:
                return match.group(1)
    return ""  # @caption present but unparsable


def check_naming(lines: list[str]) -> list[Failure]:
    """Return failures for all naming rules; warnings go to WARNINGS."""
    failures: list[Failure] = []

    seen_positions: dict[tuple[int, int], int] = {}
    current_flow = "(unknown)"

    flow_points: dict[str, list[tuple[int, int, int]]] = {}   # flow -> (x, y, line)
    loop_stack: list[dict] = []                               # loops currently open
    finished_loops: list[dict] = []

    for index, line in enumerate(lines):
        head = MICROFLOW_START_RE.match(line)
        if head:
            current_flow = head.group(1)
            seen_positions = {}
            loop_stack = []

        position = POSITION_RE.match(line)
        if position:
            point = (int(position.group(1)), int(position.group(2)))
            if point in seen_positions:
                failures.append(
                    Failure(
                        "overlapping-position",
                        f"two activities in {current_flow} sit at @position{point} "
                        f"(also line {seen_positions[point]}); one hides the other",
                        index + 1,
                    )
                )
            else:
                seen_positions[point] = index + 1
            flow_points.setdefault(current_flow, []).append((point[0], point[1], index + 1))
            if loop_stack:
                loop_stack[-1]["children"].append((point[0], point[1], index + 1))

        stripped = line.strip().lower()

        if stripped.startswith("loop ") or stripped.startswith("while "):
            loop_stack.append({"flow": current_flow, "line": index + 1, "children": []})
        elif stripped.startswith("end loop") or stripped.startswith("end while"):
            if loop_stack:
                finished_loops.append(loop_stack.pop())

        if stripped.startswith("end ") or stripped == "end":
            continue

        if DECISION_RE.match(line):
            annotations = preceding_annotations(lines, index)
            kinds = [kind for kind, _ in annotations]
            if "caption" not in kinds:
                failures.append(
                    Failure(
                        "decision-caption",
                        f"decision without @caption: {line.strip()[:70]}",
                        index + 1,
                    )
                )
                continue
            text = caption_text(annotations)
            if text is not None and text != "":
                expression = line.strip()[len(line.strip().split()[0]):].strip()
                is_enum_split = line.strip().lower().startswith("case")
                if is_enum_split and text.strip() == expression:
                    # mxcli overwrites an enum case's @caption with its expression.
                    WARNINGS.append(
                        Warning_(
                            "case-caption-dropped",
                            "mxcli wrote this split's own expression as its caption "
                            f"('{text}'); measured on 11.13.0 it discards both @caption "
                            "and @annotation on a split, so this is not the author's doing",
                            index + 1,
                        )
                    )
                elif "$" in text or re.search(r"[<>]=?|!=|\s=\s", text):
                    failures.append(
                        Failure(
                            "caption-restates-expression",
                            f"caption restates the expression: '{text}'",
                            index + 1,
                        )
                    )
                elif not text.rstrip().endswith("?"):
                    failures.append(
                        Failure(
                            "caption-not-a-question",
                            f"decision caption is not phrased as a question: '{text}'",
                            index + 1,
                        )
                    )

        elif LOOP_RE.match(line):
            annotations = preceding_annotations(lines, index)
            kinds = [kind for kind, _ in annotations]
            if "caption" in kinds:
                failures.append(
                    Failure(
                        "caption-on-loop",
                        "loop carries @caption; Mendix drops it (MDL042) -- use @annotation",
                        index + 1,
                    )
                )
            if "annotation" not in kinds:
                failures.append(
                    Failure(
                        "loop-annotation",
                        f"loop without @annotation: {line.strip()[:70]}",
                        index + 1,
                    )
                )

        elif ACTION_RE.match(line):
            annotations = preceding_annotations(lines, index)
            kinds = [kind for kind, _ in annotations]
            snippet = line.strip()[:70]
            if "caption" not in kinds:
                failures.append(
                    Failure(
                        "action-caption",
                        f"action without business-operation @caption: {snippet}",
                        index + 1,
                    )
                )
            else:
                text = caption_text(annotations)
                if text is not None and text != "" and DEFAULT_ACTION_CAPTION_RE.match(text.strip()):
                    failures.append(
                        Failure(
                            "action-caption-is-default",
                            f"action caption restates the Mendix default: '{text}'",
                            index + 1,
                        )
                    )

        # Variable names (not reached for decisions that hit the `continue` above).
        for regex, check, label in (
            (PLACEHOLDER_VAR_RE, "placeholder-variable", "placeholder variable name"),
            (THROWAWAY_VAR_RE, "placeholder-variable", "throwaway variable name"),
            (TYPE_ECHO_VAR_RE, "type-echo-variable", "variable name only restates its type"),
        ):
            for hit in regex.findall(line):
                failures.append(Failure(check, f"{label}: {hit}", index + 1))

    # FLOW02: body positions are offsets from the loop and Mendix sizes the box to fit them,
    # so judge fill density, not coordinates.
    ACTIVITY_AREA = 120 * 60
    for frame in finished_loops:
        children = frame["children"]
        if not children:
            continue
        # Estimated box: furthest child + one activity, at least an empty loop (200x180).
        box_width = max(200, max(x for x, _y, _l in children) + 150)
        box_height = max(180, max(y for _x, y, _l in children) + 80)
        filled = len(children) * ACTIVITY_AREA / (box_width * box_height)
        if filled >= 0.08:
            continue
        widest = max(children, key=lambda c: c[0] * c[1])
        failures.append(
            Failure(
                "loop-box-empty",
                f"the loop at line {frame['line']} in {frame['flow']} draws a box about "
                f"{box_width}x{box_height}px around {len(children)} activit"
                f"{'y' if len(children) == 1 else 'ies'} -- {filled * 100:.0f}% of it filled, so it "
                f"reads as an empty rectangle. A position inside a loop is an offset FROM the "
                f"loop, not a canvas coordinate: @position({widest[0]}, {widest[1]}) puts that "
                f"activity {widest[0]}px right of the loop. Use small offsets -- (40, 100) for "
                f"the first, (200, 100) for the next",
                widest[2],
            )
        )

    # FLOW01: Studio Pro shows about 1600px at a readable zoom.
    for flow, points in flow_points.items():
        if len(points) < 2:
            continue
        xs = [x for x, _y, _line in points]
        rows = {y for _x, y, _line in points}
        width = max(xs) - min(xs)
        if width > 1600:
            widest = max(points, key=lambda p: p[0])
            failures.append(
                Failure(
                    "flow-width",
                    f"{flow} is {width}px wide across {len(points)} activities on "
                    f"{len(rows)} row(s) -- it runs off the screen and has to be scrolled. "
                    f"Wrap it: about eight activities to a row, then y += 160 and back to "
                    f"the left",
                    widest[2],
                )
            )

    return failures


CHECKS = {"naming": check_naming}


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
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    text, used = collect_text(args.sources)
    if not text.strip():
        print(f"FAIL  no MDL found in {[str(s) for s in args.sources]}", file=sys.stderr)
        return 1

    lines = strip_comments(text).splitlines()

    failures: list[Failure] = []
    for skill in args.skill:
        failures.extend(CHECKS[skill](lines))

    report = {
        "verdict": "PASS" if not failures else "FAIL",
        "warnings": WARNINGS,
        "skills": args.skill,
        "sources": [str(path) for path in used],
        "lines": len(lines),
        "failures": failures,
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"{report['verdict']}  {len(failures)} failure(s) over {len(lines)} lines")
        for failure in failures:
            location = f"line {failure['line']}" if failure["line"] else "-"
            print(f"  - [{failure['check']}] {location}: {failure['message']}")
        for warning in WARNINGS:
            location = f"line {warning['line']}" if warning["line"] else "-"
            print(f"  ! [{warning['check']}] {location}: {warning['message']}")

    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
