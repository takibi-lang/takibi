#!/usr/bin/env python3
"""Positive and failure-specific controls for expected-line-ending checks."""

import subprocess
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_expected_line_endings.py"


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def run(*paths: Path) -> subprocess.CompletedProcess[str]:
    CASES.note()
    return subprocess.run(
        ["python3", str(CHECKER), *(str(path) for path in paths)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    lf = directory / "lf.expected"
    crlf = directory / "crlf.expected"
    mixed = directory / "mixed.expected"
    lf.write_bytes(b"one\ntwo\n")
    crlf.write_bytes(b"one\r\ntwo\r\n")
    mixed.write_bytes(b"one\ntwo\r\nthree\r\n")

    positive = run(lf, crlf)
    if positive.returncode != 0:
        raise SystemExit("uniform fixture control failed:\n" + positive.stdout)

    negative = run(mixed)

if negative.returncode == 0:
    raise SystemExit("mixed fixture control unexpectedly succeeded")
expected = f"{mixed} mixes LF=1 CRLF=2"
if expected not in negative.stdout:
    raise SystemExit(
        "mixed fixture control missed the expected diagnostic:\n" + negative.stdout
    )

report_pass(
    "expected-line-ending controls",
    "uniform files passed and mixed file failed",
    cases=CASES.ran)
