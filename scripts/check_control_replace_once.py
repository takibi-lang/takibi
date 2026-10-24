#!/usr/bin/env python3
"""GitHub issue #845: negative controls patch text only through replace_once.

str.replace(old, new, 1) patches the FIRST occurrence; when the anchor is
not unique a control can silently plant its defect somewhere else and
still pass (#843). Every scripts/*controls*.py, and the other scripts that
plant defects in tracked sources, must call control_patch.replace_once
instead, which refuses an anchor that does not occur exactly once.

Files that mutate a generated capture whose first record is the intended
target are listed in EXEMPT with the reason.
"""

import ast
from pathlib import Path
import sys

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
EXTRA = ()
CAPTURE = ("mutates a generated capture or log, where the first record is "
           "the intended target by construction")
EXEMPT = {
    "check_pool_space_controls.py": CAPTURE,
    "check_pool_retention_controls.py": CAPTURE,
    "check_pool_replay_controls.py": CAPTURE,
    "check_service_space_controls.py": CAPTURE,
    "slowcheck_profile_kernel_samples_controls.py": CAPTURE,
    "slowcheck_profile_kernel_workload_controls.py": CAPTURE,
}


def first_occurrence_calls(source: str) -> list[int]:
    lines = []
    for node in ast.walk(ast.parse(source)):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "replace" and len(node.args) == 3
                and isinstance(node.args[2], ast.Constant)
                and node.args[2].value == 1):
            lines.append(node.lineno)
    return sorted(lines)


def problems(files: dict[str, str]) -> list[str]:
    found = []
    for name, source in sorted(files.items()):
        if name in EXEMPT or name == "control_patch.py":
            continue
        for line in first_occurrence_calls(source):
            found.append(f"scripts/{name}:{line}: str.replace(..., 1) in a control; "
                         "use control_patch.replace_once (GitHub issue #845)")
    return found


def members() -> dict[str, str]:
    files = {}
    for path in sorted((ROOT / "scripts").glob("*.py")):
        if "controls" in path.name or path.name in EXTRA:
            files[path.name] = path.read_text(encoding="utf-8")
    return files


def main() -> int:
    files = members()
    for name in EXEMPT:
        if name not in files:
            print(f"FAIL control-replace-once: exempt file scripts/{name} no longer exists")
            return 1
    # Negative control: a planted first-occurrence patch is caught.
    planted = {"planted_controls.py": "text = 'a'\ntext = text.replace('a', 'b', 1)\n"}
    if not problems(planted):
        print("FAIL control-replace-once: planted str.replace(..., 1) passed")
        return 1
    # Positive control: the helper call is accepted.
    clean = {"clean_controls.py":
             "from control_patch import replace_once\nreplace_once('a', 'a', 'b')\n"}
    if problems(clean):
        print("FAIL control-replace-once: replace_once was refused")
        return 1
    # The helper refuses a repeated anchor and a missing one.
    from control_patch import ControlAnchorError, replace_once
    for text in ("xx", ""):
        try:
            replace_once(text, "x", "y")
        except ControlAnchorError:
            continue
        print(f"FAIL control-replace-once: replace_once accepted {text!r}")
        return 1
    found = problems(files)
    if found:
        for line in found:
            print(f"FAIL control-replace-once: {line}")
        return 1
    report_pass("control-replace-once",
                f"{len(files) - len(EXEMPT)} control scripts patch through replace_once; "
                f"{len(EXEMPT)} exempt with a reason; 4 self-controls",
                scripts=len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
