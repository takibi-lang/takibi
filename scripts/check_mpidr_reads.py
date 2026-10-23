#!/usr/bin/env python3
"""MPIDR_EL1 is read only where the platform turns it into a core number.

GitHub issue #830. The DDB and crash snapshots stored raw MPIDR_EL1 and
printed `cpu & 0xFF` (Aff0). QEMU numbers cores in Aff0; RPi5 numbers them
in Aff1 and keeps Aff0 zero, so every RPi5 core reported itself as core 0.
That stayed hidden while only core 0 entered DDB.

The rule: outside the files below, kernel code names the current core with
the platform's `cpu_id()`, never by reading MPIDR_EL1. Each allowed file
says why it must read the register itself.

Lexical: comments are stripped (Takibi comments by source_scan.code_only,
assembly `//` and `/* */` comments here), then any `mpidr_el1` token is a
read. A built-in control proves a read in another file is refused.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

ALLOWED = {
    "platform/qemu/init.tkb": "cpu_id(): QEMU's core number is Aff0",
    "platform/rpi5/init.tkb": "cpu_id(): RPi5's core number is Aff1",
    "arch/arm64/boot/entry.S": "boot parks cores before any Takibi code runs",
    "arch/arm64/boot/entry_qemu.S": "boot parks cores before any Takibi code runs",
    "platform/rpi5/jtag/smp_probe.S": "standalone hardware probe, not linked into the kernel",
}

MPIDR_RE = re.compile(r"mpidr_el1\b", re.IGNORECASE)
ASM_COMMENT_RE = re.compile(r"/\*.*?\*/|//[^\n]*", re.DOTALL)


def strip(path: str, text: str) -> str:
    if path.endswith(".tkb"):
        return code_only(text)
    return ASM_COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def violations(files: dict[str, str]) -> list[str]:
    found = []
    for path, text in sorted(files.items()):
        if path in ALLOWED:
            continue
        code = strip(path, text)
        for match in MPIDR_RE.finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            found.append(f"kernel/{path}:{line}: reads MPIDR_EL1; use cpu_id()")
    return found


def main() -> int:
    files = {}
    for suffix in ("*.tkb", "*.S"):
        for path in KERNEL.rglob(suffix):
            files[path.relative_to(KERNEL).as_posix()] = path.read_text()
    for path in ALLOWED:
        if path not in files:
            print(f"FAIL mpidr-reads: allowed file kernel/{path} is gone; "
                  "update ALLOWED", file=sys.stderr)
            return 1
    found = violations(files)
    if found:
        print("FAIL mpidr-reads:\n  " + "\n  ".join(found), file=sys.stderr)
        return 1
    # Control: the #830 shape, a snapshot reading MPIDR directly, is refused;
    # the same token in a comment is not.
    control = {"arch/arm64/kernel/x.tkb":
               "// mpidr_el1 in a comment\nlet c: usize = mrs_mpidr_el1();\n",
               "arch/arm64/kernel/x.S": "    mrs x0, mpidr_el1 // read\n"}
    if len(violations(control)) != 2:
        print("FAIL mpidr-reads: control was not refused", file=sys.stderr)
        return 1
    report_pass("mpidr-reads",
                f"MPIDR_EL1 read only in {len(ALLOWED)} reviewed file(s); "
                "a direct read elsewhere is refused",
                files=len(files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
