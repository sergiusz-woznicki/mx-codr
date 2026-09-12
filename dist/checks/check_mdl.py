#!/usr/bin/env python3
"""Assert that MDL follows the rules the new skills state.

Input is MDL text -- normally the model dump `run.sh` produces with
`describe microflow` / `describe page` / `describe snippet`, which is ground truth:
it is what actually landed in the .mpr, not what a script file claimed. Authored
`mdlsource/*.mdl` works too and is used as a fallback.

Only the naming-and-captions rules live here, because they need the MDL text --
captions, annotations and positions are not in the model catalog, so no lint rule
can see them:

    - every if / case / while carries an @caption
    - decision captions are phrased as a question, not a copy of the expression
    - every retrieve / create / change / commit / delete / call / show-page / set
      carries a business-operation @caption, not the Mendix default
    - every loop carries an @annotation and never an @caption (MDL042)
    - no placeholder variable names ($Int1, $List2, $tmp, $x)
    - no variable name that only restates its type ($Invoice_List)
    - no two activities at the same @position
    - a flow no wider than one screen: activities wrap into rows instead of
      marching off to the right (FLOW01)
    - an activity inside a loop positioned inside the loop, not on the canvas,
      because Mendix reads that coordinate as an offset from the loop (FLOW02)

The reuse-and-snippets and module-structure rules read the model, so they are
Starlark lint rules instead: .claude/lint-rules/reu001_shared_documents.star,
mod001_process_folders.star, and the existing conv005_snippet_prefix.star.

Exit 0 when every selected check passes, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Annotation lines that may sit between an @caption and the statement it binds to.
ANNOTATION_RE = re.compile(r"^\s*@(\w+)\s*(.*)$")
CAPTION_RE = re.compile(r"^\s*@caption\s+'(.*)'\s*$", re.IGNORECASE)
DECISION_RE = re.compile(r"^\s*(if|case|while)\b", re.IGNORECASE)
LOOP_RE = re.compile(r"^\s*loop\b", re.IGNORECASE)
# Object/page/call activities. `create or modify microflow` is a document head,
# not a create-object, so it is excluded by requiring a qualified entity or `$`.
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
MICROFLOW_START_RE = re.compile(
    r"^\s*create (?:or (?:modify|replace) )?(?:microflow|nanoflow)\s+([\w.]+)", re.IGNORECASE
)
PLACEHOLDER_VAR_RE = re.compile(
    r"\$(?:int|bool|boolean|str|string|dec|decimal|date|datetime|list|obj|object|var|num|item)\d+\b",
    re.IGNORECASE,
)
THROWAWAY_VAR_RE = re.compile(r"\$(?:tmp|temp|foo|bar|x|y|z|aa)\b", re.IGNORECASE)
TYPE_ECHO_VAR_RE = re.compile(r"\$\w+_(?:list|object|obj)\b", re.IGNORECASE)
MICROFLOW_HEAD_RE = re.compile(
    r"^\s*create (?:or (?:modify|replace) )?microflow\s+([\w.]+)", re.IGNORECASE
)


WARNINGS: list = []


class Failure(dict):
    def __init__(self, check: str, message: str, line: int | None = None):
        super().__init__(check=check, message=message, line=line)


class Warning_(dict):
    """Something the author cannot fix -- reported, but not counted against them."""

    def __init__(self, check: str, message: str, line: int | None = None):
        super().__init__(check=check, message=message, line=line)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    # CLAUDE.md tells authors to quote every identifier (Module."Name"). Describe
    # output comes back unquoted, an authored script does not; MDL strings are
    # single-quoted, so dropping double quotes is safe and makes both parse alike.
    text = text.replace('"', "")
    kept = [line for line in text.splitlines() if not line.lstrip().startswith("--")]
    return "\n".join(kept)


def preceding_annotations(lines: list[str], index: int) -> list[tuple[str, str]]:
    """Annotations attached to lines[index], walking back over @position etc."""
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
    for kind, raw in annotation_lines:
        if kind == "caption":
            match = CAPTION_RE.match(raw)
            if match:
                return match.group(1)
    return ""  # @caption present but unparsable


def check_naming(lines: list[str]) -> list[Failure]:
    failures: list[Failure] = []

    # Two activities at the same coordinates are drawn on top of each other, and
    # one of them is simply not visible in Studio Pro. Positions are per flow.
    seen_positions: dict[tuple[int, int], int] = {}
    current_flow = "(unknown)"

    # FLOW01/FLOW02 need the shape of each flow, not just one line at a time: how
    # far right it runs, and where a loop's body sits relative to the loop.
    flow_points: dict[str, list[tuple[int, int, int]]] = {}   # flow -> (x, y, line)
    loop_depth = 0
    loop_stack: list[tuple[int, int, int]] = []               # (x, y, line) of each open loop
    pending_position: tuple[int, int, int] | None = None

    for index, line in enumerate(lines):
        head = MICROFLOW_START_RE.match(line)
        if head:
            current_flow = head.group(1)
            seen_positions = {}
            loop_depth = 0
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
            pending_position = (point[0], point[1], index + 1)

        stripped = line.strip().lower()

        # A loop opens a coordinate space of its own. Mendix stores every position as
        # RelativeMiddlePoint -- relative to the parent -- so an activity written at
        # the canvas coordinate it looks like it should have lands that far INSIDE the
        # loop, and Studio Pro grows the loop box to contain it. Measured: a body at
        # (560, 360) inside a loop at (560, 200) produced a loop 670px wide, and one
        # at (40, 100) produced 200px. The first is unreadable on screen.
        if stripped.startswith("loop ") or stripped.startswith("while "):
            loop_stack.append(pending_position or (0, 0, index + 1))
            loop_depth += 1
        elif stripped.startswith("end loop") or stripped.startswith("end while"):
            if loop_stack:
                loop_stack.pop()
            loop_depth = max(0, loop_depth - 1)
        elif loop_depth and pending_position and pending_position[2] == index:
            pass  # the position line itself; the body check happens below

        if loop_depth and POSITION_RE.match(line):
            loop_x, loop_y, loop_line = loop_stack[-1] if loop_stack else (0, 0, 0)
            body_x, body_y = int(POSITION_RE.match(line).group(1)), int(POSITION_RE.match(line).group(2))
            # Two tells, both of a canvas coordinate used where an offset belongs:
            # a y offset no real body needs (a body sits 100-200 under the loop's top
            # edge, however many activities it holds, because they extend sideways),
            # and an x that matches the loop's own -- the author copied it. Neither
            # fires on a long body written correctly, which keeps y small.
            if body_y >= 300 or (body_x >= 300 and abs(body_x - loop_x) <= 40):
                failures.append(
                    Failure(
                        "loop-body-position",
                        f"in {current_flow}, the activity at @position({body_x}, {body_y}) is "
                        f"inside the loop at @position({loop_x}, {loop_y}) (line {loop_line}), and "
                        f"Mendix reads a position inside a loop as an offset FROM the loop -- so "
                        f"this stretches the loop box to about {body_x + 120}px wide and leaves it "
                        f"looking empty. Use a small offset instead: @position(40, 100) for the "
                        f"first activity in the body, (200, 100) for the next",
                        index + 1,
                    )
                )

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
                    # mxcli writes the split expression over whatever @caption the
                    # script gave an enum `case`, so a question caption cannot
                    # survive here. Reported, not held against the author.
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

        for regex, check, label in (
            (PLACEHOLDER_VAR_RE, "placeholder-variable", "placeholder variable name"),
            (THROWAWAY_VAR_RE, "placeholder-variable", "throwaway variable name"),
            (TYPE_ECHO_VAR_RE, "type-echo-variable", "variable name only restates its type"),
        ):
            for hit in regex.findall(line):
                failures.append(Failure(check, f"{label}: {hit}", index + 1))

    # FLOW01: a flow that runs off the screen. Studio Pro shows roughly 1600px at a
    # readable zoom; measured, a 17-activity flow written as one row spanned 2400px
    # and had to be read at 75% and scrolled. Activities wrap into rows instead:
    # y += 160 and back to the left margin.
    for flow, points in flow_points.items():
        if len(points) < 2:
            continue
        xs = [x for x, _y, _line in points]
        rows = {y for _x, y, _line in points}
        width = max(xs) - min(xs)
        if width > 1600 and len(rows) <= 2:
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
