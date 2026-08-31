#!/usr/bin/env python3
"""Positive and build-faithful negative controls for the DDB inventory check."""

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_ddb_command_inventory.py"
SOURCE = ROOT / "kernel/arch/arm64/kernel/exception_evidence.tkb"


def run(*extra: str) -> subprocess.CompletedProcess[str]:
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
    changed = Path(temporary) / "exception_evidence.tkb"
    source = SOURCE.read_text(encoding="ascii")
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

if negative.returncode == 0:
    raise SystemExit("negative DDB inventory control unexpectedly succeeded")
expected = "DDB command drift in dispatcher: extra staleprobe"
if expected not in negative.stdout:
    raise SystemExit(
        "negative DDB inventory control missed the expected diagnostic:\n"
        + negative.stdout
    )

print("PASS ddb-command-inventory controls: positive succeeded and stale dispatcher failed")
