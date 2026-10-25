#!/usr/bin/env python3
"""Every QEMU runner that hands the guest a writable disk judges it afterwards.

GitHub issue #1033: the host's e2fsck once ran after one lane only, so a
leak or a broken directory written by any other lane (ext2 exhaustion,
churn, the fault and rollback lanes) went unseen. scripts/ext2_postcheck.py
is the one postcheck; this refuses a runner whose QEMU command line has a
`-drive` without `readonly=on` and which does not call it. A runner added
later without it fails here, not after its first silent corruption.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
POSTCHECK = "scripts/ext2_postcheck.py"
# This check and the postcheck's own controls name the pieces without
# starting a guest.
EXEMPT = {"scripts/check_ext2_postcheck_lanes.py",
          "scripts/slowcheck_ext2_postcheck_controls.py",
          "scripts/ext2_postcheck.py"}
CALL = re.compile(r"ext2_postcheck\.py")


def code_lines(text):
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        yield number, line


def problems(name, text):
    drives = [(number, line) for number, line in code_lines(text)
              if "-drive" in line and "file=" in line
              and "readonly=on" not in line]
    if not drives:
        return [], False
    if any(CALL.search(line) for _, line in code_lines(text)):
        return [], True
    number = drives[0][0]
    return [f"{name}:{number}: hands QEMU a writable -drive but never runs "
            f"{POSTCHECK} on it after the guest stops (#1033)"], True


def main():
    found = []
    writers = 0
    for path in sorted((ROOT / "scripts").glob("*")):
        if path.suffix not in (".sh", ".py") or not path.is_file():
            continue
        name = path.relative_to(ROOT).as_posix()
        if name in EXEMPT:
            continue
        failures, writes = problems(name, path.read_text())
        found.extend(failures)
        writers += writes
    for problem in found:
        print(f"ERROR\text2-postcheck-lanes: {problem}")
    if found:
        print("FAIL ext2-postcheck-lanes")
        return 1
    report_pass("ext2-postcheck-lanes",
                f"{writers} runners hand QEMU a writable disk; each runs "
                f"{POSTCHECK} after the guest stops", runners=writers)
    return 0


if __name__ == "__main__":
    sys.exit(main())
