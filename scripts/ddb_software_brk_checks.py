#!/usr/bin/env python3
"""The claims a software-BRK backtrace must satisfy, on either target.

The walk this checks is target-independent by construction: it is DDB
reading compiler-generated frame pointers out of the same kernel, and every
question below is about the shape of that chain rather than about the
machine underneath it. Which is why it lives here instead of twice.

It was twice. The QEMU lane asked four of these with grep and the RPi5 board
lane asked six in Python, and the two only the board lane had -- that every
compiler frame lies inside the linker-owned generated-text range, and that
the walk does not end at a user boundary -- were the whole reason the board
lane looked like it earned a second reset of the shared RPi5 per aggregate
run. They did not need the board. They needed to be written down once.

What genuinely needs silicon is not here: taking the BRK debug exception on
a real Cortex-A76, the Debug Probe UART path, and loading a checkpointed
image over SWD. `make kernelcheck-ddb-rpi5-software` still asks those.
"""

import argparse
import re
import sys

# The frame-pointer chain starts in the explicit assembly bridge, walks
# compiler-generated frames, and must terminate at the boot-assembly
# boundary rather than running off into whatever the fp happened to hold.
ROOT = r"^ddb: bt frame=0 pc=0x[0-9a-f]+ boundary=assembly-bridge$"
COMPILER_FRAME = r"^ddb: bt frame=[1-9][0-9]* pc=0x([0-9a-f]+) fp=0x[0-9a-f]+$"
TERMINAL = (r"^ddb: bt frame=[1-9][0-9]* pc=0x[0-9a-f]+ fp=0x[0-9a-f]+ "
            r"boundary=assembly$")
STOP = r"^ddb: bt stop=assembly-boundary fp=0x[0-9a-f]+$"


def backtrace_problems(text, generated_start, generated_end):
    """Every claim the transcript fails. Empty means the walk is sound."""
    problems = []
    if not re.search(ROOT, text, re.MULTILINE):
        problems.append("backtrace root was not the assembly bridge")

    compiler_pcs = [int(m.group(1), 16)
                    for m in re.finditer(COMPILER_FRAME, text, re.MULTILINE)]
    if not compiler_pcs:
        problems.append("backtrace was root-only; no compiler frame reported")
    else:
        # A frame outside the linker-owned range is not a compiler frame that
        # was walked, it is a number that happened to look like one.
        outside = [pc for pc in compiler_pcs
                   if not generated_start <= pc < generated_end]
        if outside:
            problems.append(
                "compiler frame outside .text.takibi "
                f"[0x{generated_start:x}, 0x{generated_end:x}): "
                + ", ".join(f"0x{pc:x}" for pc in outside))

    if not re.search(TERMINAL, text, re.MULTILINE):
        problems.append("no terminal assembly frame was reported")
    if not re.search(STOP, text, re.MULTILINE):
        problems.append("the walk did not stop at the assembly boundary")
    # The checkpoint stands in the kernel, so a walk that ends at a user
    # boundary did not walk the chain this lane exists to prove.
    if "ddb: bt stop=user-boundary" in text:
        problems.append("the walk ended at a user boundary")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True)
    parser.add_argument("--generated-start", required=True,
                        type=lambda value: int(value, 0))
    parser.add_argument("--generated-end", required=True,
                        type=lambda value: int(value, 0))
    parser.add_argument("--label", required=True,
                        help="lane name to print in a failure")
    args = parser.parse_args()
    if args.generated_start >= args.generated_end:
        print(f"FAIL {args.label}: generated-text bounds are empty "
              f"(0x{args.generated_start:x} >= 0x{args.generated_end:x})",
              file=sys.stderr)
        return 1
    with open(args.log, encoding="ascii", errors="replace") as handle:
        text = handle.read().replace("\r", "")
    problems = backtrace_problems(text, args.generated_start,
                                  args.generated_end)
    if problems:
        for problem in problems:
            print(f"FAIL {args.label}: software BRK walk -- {problem}",
                  file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
