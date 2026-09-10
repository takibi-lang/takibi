#!/usr/bin/env python3
"""Controls for the live RPi5 kernel-byte writer without using the board."""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "scripts" / "rpi5_set_kernel_byte.sh"


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="ascii")
    path.chmod(0o755)


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def run_case(mode: str) -> subprocess.CompletedProcess[str]:
    CASES.note()
    with tempfile.TemporaryDirectory() as temporary:
        tree = Path(temporary)
        scripts = tree / "scripts"
        tools = tree / "tools"
        scripts.mkdir()
        tools.mkdir()
        shutil.copy2(SOURCE, scripts / SOURCE.name)
        (tree / "kernel.elf").write_bytes(b"ELF")
        executable(
            tools / "llvm-nm-19",
            "#!/bin/sh\n"
            "printf '%s\\n' '0000000000555651 B test_flag' "
            "'0000000000201820 T rpi5_irq_dispatch_inner'\n",
        )
        if mode == "success":
            openocd = "printf '%s\\n' '0x00555651: 01'\n"
        elif mode == "silent_error":
            openocd = ("printf '%s\\n' "
                       "'Error: Opcode 0x38001401, DSCR.ERR=1, DSCR.EL=1'\n")
        else:
            openocd = "printf '%s\\n' 'shutdown command invoked'\n"
        executable(tools / "openocd", "#!/bin/sh\n" + openocd + "exit 0\n")
        environment = os.environ.copy()
        environment["PATH"] = f"{tools}:{environment['PATH']}"
        return subprocess.run(
            [str(scripts / SOURCE.name), str(tree / "kernel.elf"),
             "test_flag", "1"],
            text=True, capture_output=True, env=environment, check=False,
        )


def main() -> int:
    success = run_case("success")
    if success.returncode != 0:
        raise SystemExit("valid read-back failed:\n" + success.stdout + success.stderr)
    silent_error = run_case("silent_error")
    if silent_error.returncode == 0 or "could not set" not in silent_error.stderr:
        raise SystemExit("status-zero DSCR.ERR was accepted")
    no_readback = run_case("no_readback")
    if no_readback.returncode == 0 or "read-back" not in no_readback.stderr:
        raise SystemExit("missing read-back was accepted")
    report_pass(
        "rpi5 kernel-byte writer controls",
        "verified writes pass, while status-zero DSCR errors and "
        "missing read-back fail",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
