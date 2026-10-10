#!/usr/bin/env python3
"""No interrupt dispatcher decides on the raw GICC_IAR word.

GitHub issue #632. GICC_IAR is not the interrupt number alone: for an SGI,
bits [12:10] carry the CPU that sent it. Both platform dispatchers compared
the raw word with the world-stop SGI's number 1, so a stop that core 0 began
(IAR 1) was served and one that core 3 began (IAR 0xC01) fell through every
branch. No core ever acknowledged a world stop begun on a peer. Under the
four-core churn workload that first fail-stopped the kernel and then hung it
at the ASID rollover, and it hid for as long as every stop happened to start
on core 0.

The rule, per file that reads GICC_IAR (`gicc.iar`):
  - the read is bound to a name (the raw word), and some name is bound to
    that word `& 0x3FF` (the INTID);
  - the raw name appears in no `==`/`!=` comparison and is not passed on as
    an interrupt number -- its one legitimate use is the EOI write, which
    must hand back the whole word to deactivate that sender's SGI.

Lexical, like check_irq_restore_sites.py: it reads the platform intc files,
not the call graph. The file's own control plants the original shape and
requires the check to refuse it.
"""

import pathlib
import re
import sys

from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
INTC_GLOB = "kernel/platform/*/intc.tkb"

# The read is `gicc.iar` through the GIC's IoHandle (#637 step A); the raw
# `*gicc_iar` spelling it replaced is still recognized, so a revert is seen.
READ = re.compile(r"let\s+(\w+)\s*:\s*u32\s*=\s*(?:\*gicc_iar|gicc\.iar)\s*;")
MASKED = r"let\s+\w+\s*:\s*u32\s*=\s*{raw}\s*&\s*0x3[fF][fF]\s*;"


def problems_in(text: str, relative: str) -> tuple[int, list[str]]:
    """Return (reads examined, problems) for one intc file's text."""
    problems = []
    reads = READ.findall(text)
    for raw in reads:
        if not re.search(MASKED.format(raw=re.escape(raw)), text):
            problems.append(
                f"{relative}: `{raw}` holds GICC_IAR and no name is bound to "
                f"`{raw} & 0x3FF`. Decide on the INTID: an SGI's IAR carries "
                "its sender in bits [12:10] (#632)")
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("//", 1)[0]
            compared = re.search(
                rf"\b{re.escape(raw)}\b\s*[!=]=|[!=]=\s*\b{re.escape(raw)}\b",
                code)
            passed_on = re.search(rf"\b{re.escape(raw)}\s+as\s+usize", code)
            if compared or passed_on:
                problems.append(
                    f"{relative}:{number}: the raw GICC_IAR word `{raw}` is "
                    "compared or passed on as an interrupt number; only the "
                    "EOI write may use it (#632)")
    return len(reads), problems


def control() -> bool:
    """The pre-#632 dispatcher shape must be refused."""
    for read in ("*gicc_iar", "gicc.iar"):
        planted = f"""
    let id: u32 = {read};
    if (id == QEMU_WORLD_STOP_SGI) {{
        gicc.eoir = id;
    }}
"""
        reads, found = problems_in(planted, "control")
        if not (reads == 1 and len(found) >= 2):
            return False
    return True


def main() -> int:
    if not control():
        print("FAIL gic-iar-intid: the control plants the pre-#632 raw "
              "comparison and the check did not refuse it", file=sys.stderr)
        return 1
    files = sorted(REPO.glob(INTC_GLOB))
    total_reads = 0
    problems = []
    for path in files:
        relative = str(path.relative_to(REPO))
        reads, found = problems_in(path.read_text(), relative)
        total_reads += reads
        problems.extend(found)
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL gic-iar-intid: {len(problems)} place(s) decide on the "
              "raw GICC_IAR word", file=sys.stderr)
        return 1
    report_pass("gic-iar-intid",
                f"{total_reads} GICC_IAR read(s) in {len(files)} platform "
                "dispatcher(s) decide on the INTID and EOI with the raw word, "
                "and the pre-#632 raw comparison is refused",
                counts=total_reads)
    return 0


if __name__ == "__main__":
    sys.exit(main())
