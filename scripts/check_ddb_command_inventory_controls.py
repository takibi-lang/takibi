#!/usr/bin/env python3
"""Positive and build-faithful negative controls for the DDB inventory check."""

import subprocess
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_ddb_command_inventory.py"
SOURCE = ROOT / "kernel/arch/arm64/kernel/exception_evidence.tkb"


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def run(*extra: str) -> subprocess.CompletedProcess[str]:
    CASES.note()
    return subprocess.run(
        ["python3", str(CHECKER), *extra],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


positive = run()
if positive.returncode != 0:
    raise SystemExit("positive DDB inventory control failed:\n" + positive.stdout)

with tempfile.TemporaryDirectory() as temporary:
    commented = Path(temporary) / "commented_exception_evidence.tkb"
    source = SOURCE.read_text(encoding="ascii")
    commented.write_text(
        source
        + '\n// if (ddb_command_is(line as []u8, length, bs"staleprobe")) {}\n'
        + '/* ddb_command_is(line as []u8, length, bs"otherprobe") */\n',
        encoding="ascii",
    )
    commented_result = run("--source", str(commented))
    if commented_result.returncode != 0:
        raise SystemExit(
            "commented DDB command shape was treated as active:\n"
            + commented_result.stdout
        )

    changed = Path(temporary) / "exception_evidence.tkb"
    needle = 'if (ddb_command_is(line as []u8, length, bs"continue")) {'
    changed.write_text(
        source.replace(
            needle,
            'if (ddb_command_is(line as []u8, length, bs"staleprobe")) {\n'
            '            ddb_puts("stale probe\\n");\n'
            '        } else '
            + needle,
            1,
        ),
        encoding="ascii",
    )
    negative = run("--source", str(changed))

    qemu_test = ROOT / "scripts/run_kernel_ddb_qemutest.sh"
    qemu_source = qemu_test.read_text(encoding="ascii")
    qemu_changed = Path(temporary) / "run_kernel_ddb_qemutest.sh"
    qemu_changed.write_text(
        qemu_source.replace(
            "^ddb: wait pid=10 state=blocked waits-for event=uart-rx queued=1$",
            "^ddb: wait pid=10 state=blocked waits-for event=uart-rx$",
            1,
        ),
        encoding="ascii",
    )
    qemu_negative = run("--qemu_test", str(qemu_changed))

if negative.returncode == 0:
    raise SystemExit("negative DDB inventory control unexpectedly succeeded")
expected = "DDB command drift in dispatcher: extra staleprobe"
if expected not in negative.stdout:
    raise SystemExit(
        "negative DDB inventory control missed the expected diagnostic:\n"
        + negative.stdout
    )

if qemu_negative.returncode == 0:
    raise SystemExit("negative DDB waker fixture control unexpectedly succeeded")
expected_waker = "DDB waker fixture drift: missing"
if expected_waker not in qemu_negative.stdout:
    raise SystemExit(
        "negative DDB waker fixture control missed the expected diagnostic:\n"
        + qemu_negative.stdout
    )

report_pass(
    "ddb-command-inventory controls",
    "positive succeeded; stale dispatcher and missing waker assertion failed",
    cases=CASES.ran)
