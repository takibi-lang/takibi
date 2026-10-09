#!/usr/bin/env python3
"""Check race overlays against tracked sources before compiling their kernels."""

from pathlib import Path
import sys

from build_qemu_race_window import WINDOWS, spin
from pass_line import report_pass


def validate(sources, windows):
    errors = []
    for name, window in windows.items():
        edited = dict(sources)
        changes = list(window.get("prepare", []))
        if window["spin"] is not None:
            file, anchor, peer_only = window["spin"]
            changes.append((file, anchor, anchor + spin(name, peer_only)))
        checks = window["check"]
        changes.extend([checks] if isinstance(checks, tuple) else checks)
        for file, before, after in changes:
            count = edited[file].count(before)
            if count != 1:
                errors.append(f"{name}: kernel/{file}: expected one anchor, found {count}")
                continue
            edited[file] = edited[file].replace(before, after)
    return errors


def main():
    files = set()
    for window in WINDOWS.values():
        files.update(file for file, _, _ in window.get("prepare", []))
        if window["spin"] is not None:
            files.add(window["spin"][0])
        checks = window["check"]
        for file, _, _ in [checks] if isinstance(checks, tuple) else checks:
            files.add(file)
    sources = {file: (Path("kernel") / file).read_text(encoding="ascii")
               for file in files}
    errors = validate(sources, WINDOWS)
    # Faithful controls: the old per-CPU accessor, an absent anchor and a
    # duplicated anchor must each fail before any kernel compiler is run.
    stale = {**WINDOWS["633"], "check": list(WINDOWS["633"]["check"])}
    file, before, after = stale["check"][1]
    stale["check"][1] = (file, before.replace(
        "execution_state[execution_cpu_index()]", "execution_here()"), after)
    if not validate(sources, {"633": stale}):
        errors.append("control: the obsolete per-CPU accessor was accepted")
    for mutation, replacement in (("absent", ""), ("duplicate", before + before)):
        changed = {**sources, file: sources[file].replace(before, replacement)}
        if not validate(changed, {"633": WINDOWS["633"]}):
            errors.append(f"control: {mutation} anchor was accepted")
    if errors:
        for error in errors:
            print(f"ERROR race-window-anchors: {error}")
        return 1
    report_pass("race-window-anchors",
                "all armed/reverted edits match tracked sources exactly once; "
                "obsolete, absent and duplicate anchors are refused",
                windows=len(WINDOWS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
