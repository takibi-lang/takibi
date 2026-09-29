#!/usr/bin/env python3
"""Controls for the cursor-reply check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_no_cursor_reply.py"
CASES = CaseCount()

# Assembled, so this file does not contain the literal it plants.
HEX_ESC = "\\" + "x1b"
OCTAL_ESC = "\\" + "033"
STRIPS = 'text = text.replace(b"' + HEX_ESC + '[6n", b"")\n'
REPLIES = 'connection.sendall(b"' + HEX_ESC + '[1;1R")\n'
OCTAL = 'serial.write(b"' + OCTAL_ESC + '[24;80R")\n'
PROSE = "# an answer arrives as input text instead (`[1;1R`)\n"


def run(body, where="scripts"):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        (root / "scripts").mkdir()
        (root / "kernel" / "tests" / "common").mkdir(parents=True)
        for name in (CHECK, "pass_line.py"):
            shutil.copy(REPO / "scripts" / name, root / "scripts" / name)
        target = root / where / "probe.py"
        target.write_text(body)
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin",
                 "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run(STRIPS) != 0:
        failures.append("removing the query from a capture was refused")
    if run(PROSE) != 0:
        failures.append("a comment describing the reply was refused")
    if run(REPLIES) == 0:
        failures.append("a driver answering in hex escapes passed")
    if run(OCTAL) == 0:
        failures.append("a reply spelled in octal escapes passed")
    if run(REPLIES, "kernel/tests/common") == 0:
        failures.append("a reply under kernel/tests passed")
    if failures:
        for line in failures:
            print(f"FAIL no-cursor-reply controls: {line}", file=sys.stderr)
        return 1
    report_pass("no-cursor-reply controls",
                f"{CASES.ran} cases -- removing the query and describing the "
                "reply pass; a reply in hex or octal, under scripts/ or "
                "kernel/tests/, is refused",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
