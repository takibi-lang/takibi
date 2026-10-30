#!/usr/bin/env python3
"""GICC_EOIR is written only by irq_eoi and the GIC's own SGI paths.

GitHub issue #774. An ordinary interrupt is a linear claim from irq_take
(kernel/platform/<target>/irq_source.tkb) that only its source's clear
consumes, and the EOI takes the IrqAcked that clear returns. That holds
only while the EOI has no other spelling: a `gicc.eoir = iar;` written
straight in a dispatcher would end the interrupt without its claim, the
#497 shape (a tick path that EOIed and left the PMU line asserted) with
the claim simply never taken.

The rule: `eoir` is written only in the files below. Each allowed file
says why. Lexical: comments are stripped by source_scan.code_only, then
any `.eoir =` is a write. A built-in control proves a write elsewhere is
refused.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

ALLOWED = {
    "platform/qemu/irq_source.tkb": "irq_eoi: takes the IrqAcked a source clear returns",
    "platform/rpi5/irq_source.tkb": "irq_eoi: takes the IrqAcked a source clear returns",
    "arch/arm64/kernel/gicv2.tkb": "the debug-stop and world-stop SGIs, served by the GIC head",
}

EOIR_RE = re.compile(r"\.\s*eoir\s*=(?!=)")


def violations(files: dict[str, str]) -> list[str]:
    found = []
    for path, text in sorted(files.items()):
        if path in ALLOWED:
            continue
        code = code_only(text)
        for match in EOIR_RE.finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            found.append(f"kernel/{path}:{line}: writes GICC_EOIR; "
                         "end the interrupt with irq_eoi(acked, iar)")
    return found


def main() -> int:
    files = {}
    for path in KERNEL.rglob("*.tkb"):
        files[path.relative_to(KERNEL).as_posix()] = path.read_text()
    for path in ALLOWED:
        if path not in files:
            print(f"FAIL irq-eoi: allowed file kernel/{path} is gone; "
                  "update ALLOWED", file=sys.stderr)
            return 1
    found = violations(files)
    if found:
        print("FAIL irq-eoi:\n  " + "\n  ".join(found), file=sys.stderr)
        return 1
    # Control: the #497 shape, a dispatcher arm that EOIs directly, is
    # refused; the same text in a comment, and a comparison, are not.
    control = {"platform/qemu/intc.tkb":
               "// gicc.eoir = iar;\nif (gicc.eoir == 0) {}\n"
               "    gicc.eoir = iar;\n"}
    if len(violations(control)) != 1:
        print("FAIL irq-eoi: control was not refused exactly once", file=sys.stderr)
        return 1
    report_pass("irq-eoi",
                f"GICC_EOIR written only in {len(ALLOWED)} reviewed file(s); "
                "a direct EOI elsewhere is refused",
                files=len(files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
