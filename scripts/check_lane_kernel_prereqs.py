#!/usr/bin/env python3
"""Public Make targets reach kernel build outputs only under the build lock.

GitHub issue #645's land failure. `litmuscheck: $(KERNEL_RPI5_MAIN_O)` made
the top-level make build the RPi5 kernel object -- and the ext2 image it
pulls in -- while an allcheck kernel lane's recursive make, holding
_build/kernel-build.lock, built the same image. One recipe's mv ran under
the other's e2cp, and allcheck failed twice with "ext2.img.tmp: No such
file". Every lane builds kernel outputs through
`$(KERNEL_BUILD_LOCK_RUN) $(MAKE) <target>`; a public phony target that
names one as a direct prerequisite escapes the lock.

So: a .PHONY target whose name does not start with `_` (the private,
already-locked inner targets) must not list, as a direct prerequisite, a
kernel build output -- a `$(KERNEL_..._O/_ELF/_IMG/_BIN/...)` variable or a
`kernel/build/` path. REVIEWED holds the exceptions with their reason.

GitHub issue #788 is the same shape one tree over: allbuild's sub-make and a
top-level linuxcheck both compiled linux_user/.../*_exe.o, and one linked
while the other rewrote the object. linux_user outputs are built only by
`$(LINUX_BUILD_LOCK_RUN) $(MAKE) _linuxbuild`, so the same rule covers
`$(LINUX_USER_BINS)`, `$(LINUX_USER_OBJS)` and `linux_user/**.exe|.o`.

GitHub issue #1343 is the same escape one name further on:
kernel-memory-map-check listed `_kernelbuild-qemu`, so the private target that
assumes the lock ran without it. A public target therefore names no private
`_kernel...` or `_linux...` target either. And a recipe's temporary carries
$(MAKE_PID), so an unlocked file goal still cannot share one with a lane.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import per_file

MAKEFILE = pathlib.Path("Makefile")
OUTPUT = re.compile(r"\$\(KERNEL_\w*_(O|ELF|IMG|IMAGE|BIN|METADATA)\)|\bkernel/build/"
                    r"|\$\(LINUX_USER_(BINS|OBJS)\)|\blinux_user/\S*\.(exe|o)\b")
PRIVATE = re.compile(r"(?<!\S)_(?:kernel|linux)[\w.-]*")
SHARED_TEMPORARY = re.compile(r"^\t.*\$(@|\([A-Z_]+\))\S*\.tmp\b")
RULE = re.compile(r"^([A-Za-z0-9_.%/$()-][^:=\t#]*?)\s*:(?![=:])\s*(.*)$")
PHONY = re.compile(r"^\.PHONY\s*:\s*(.*)$")

# target -> why its kernel-output prerequisite cannot race a lane.
REVIEWED: dict = {}


@per_file
def phony_rules(text: str) -> tuple:
    """((target, prerequisites, line), ...) for public phony targets."""
    lines = []
    joined = ""
    for raw in text.splitlines():
        if raw.endswith("\\"):
            joined += raw[:-1] + " "
            continue
        lines.append(joined + raw)
        joined = ""
    phony = set()
    for line in lines:
        match = PHONY.match(line)
        if match:
            phony.update(match.group(1).split())
    found = []
    for number, line in enumerate(lines, 1):
        if line.startswith("\t") or line.startswith("#"):
            continue
        match = RULE.match(line)
        if not match:
            continue
        prereqs = match.group(2).split("|")[0].split(";")[0]
        for target in match.group(1).split():
            if target in phony and not target.startswith("_"):
                found.append((target, prereqs, number))
    return tuple(found)


def problems(text: str, reviewed=None) -> tuple:
    reviewed = REVIEWED if reviewed is None else reviewed
    found = []
    for target, prereqs, number in phony_rules(text):
        hit = OUTPUT.search(prereqs) or PRIVATE.search(prereqs)
        if hit and target not in reviewed:
            found.append(f"Makefile logical line {number}: public target {target} "
                         f"depends directly on a locked build output {hit.group(0)}; "
                         "build it with $(KERNEL_BUILD_LOCK_RUN) or $(LINUX_BUILD_LOCK_RUN) "
                         "$(MAKE) <target> in the recipe so it cannot race a lane "
                         "holding that build lock")
    for number, line in enumerate(text.splitlines(), 1):
        if SHARED_TEMPORARY.match(line) and "$(MAKE_PID)" not in line:
            found.append(f"Makefile line {number}: a recipe temporary without "
                         "$(MAKE_PID) is shared by two make levels: "
                         + line.strip())
    return tuple(found)


def main() -> int:
    text = MAKEFILE.read_text(encoding="ascii")
    found = problems(text)
    for line in found:
        print(f"FAIL lane-kernel-prereqs: {line}")
    if found:
        return 1
    report_pass("lane-kernel-prereqs",
                "no public phony target names a kernel or linux_user build "
                "output or private target as a direct prerequisite, and every "
                "recipe temporary is per-process", targets=len(phony_rules(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
