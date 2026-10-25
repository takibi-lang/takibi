#!/usr/bin/env python3
"""The ext2 equivalence rows run only in the boot that compares them.

GitHub issue #1075: #1034 ran /lib/ext2-eq.sh from kernel/tests/ext2/init.sh
in every QEMU boot, while only scripts/run_kernel_qemutest.sh compares
/eq-log; the other lanes paid for rows nothing read and the allcheck went
past its lane-seconds budget. This refuses an init.sh that runs the script
outside `if [ -e /lib/ext2-eq.enable ]`, and a comparing runner that does not plant
/lib/ext2-eq.enable or compares without the same switch.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
INIT = "kernel/tests/ext2/init.sh"
RUNNER = "scripts/run_kernel_qemutest.sh"
ASH = "kernel/tests/common/ash/ash.stdin"
MARKER = "/lib/ext2-eq.enable"


def listed_dirs(ash):
    """Directories the shared ash fixture lists; a marker there shows up."""
    dirs = set()
    for line in ash.splitlines():
        if line.lstrip().startswith("#"):
            continue
        for match in re.finditer(r"(?:/bin/)?\bls((?:\s+[-/][^\s;|&]*)*)", line):
            paths = [a for a in match.group(1).split() if a.startswith("/")]
            dirs.update(paths or ["/"])
    return dirs


def problems(init, runner, ash=""):
    found = []
    parent = MARKER.rsplit("/", 1)[0] or "/"
    if parent in listed_dirs(ash):
        found.append(f"{MARKER}: {parent} is listed by {ASH}, so the "
                     "marker would change the ash transcript (#1075)")
    code = [line for line in init.splitlines()
            if not line.lstrip().startswith("#")]
    gated = False
    runs = 0
    for line in code:
        if re.match(r"\s*if \[ -e /lib/ext2-eq.enable \]; then\s*$", line):
            gated = True
        elif re.match(r"\s*fi\s*$", line):
            gated = False
        elif "/lib/ext2-eq.sh" in line:
            runs += 1
            if not gated:
                found.append(f"{INIT}: runs /lib/ext2-eq.sh outside "
                             "`if [ -e /lib/ext2-eq.enable ]` (#1075)")
    if runs == 0:
        found.append(f"{INIT}: no longer runs /lib/ext2-eq.sh; update this check")
    if "write /dev/null /lib/ext2-eq.enable" not in runner:
        found.append(f"{RUNNER}: does not plant /lib/ext2-eq.enable on its disk")
    if not re.search(r'if \[ "\$EXT2_EQ" = on \]; then\n(?:.*\n)*?\s+(?:if ! )?python3 '
                     r'"\$REPO_ROOT/scripts/ext2_eq.py" compare', runner):
        found.append(f"{RUNNER}: compares the rows outside its EXT2_EQ switch")
    return found, runs


def main():
    init = (ROOT / INIT).read_text()
    runner = (ROOT / RUNNER).read_text()
    found, runs = problems(init, runner, (ROOT / ASH).read_text())
    for problem in found:
        print(f"ERROR\text2-eq-gate: {problem}")
    if found:
        print("FAIL ext2-eq-gate")
        return 1
    report_pass("ext2-eq-gate", f"{runs} run of /lib/ext2-eq.sh, gated on "
                "/lib/ext2-eq.enable, which only the comparing runner plants", runs=runs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
