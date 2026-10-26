#!/usr/bin/env python3
"""The load programs' cross builds name every compiler they can reach.

GitHub issue #1154 (followup). scripts/build_load_programs.sh built stress-ng
with only CC set to the Bootlin cross compiler. stress-ng probes optional C++
features with $(CXX) and links with $(CXX) once a C++ object exists, so on a
host with Eigen headers the host's g++ compiled stress-eigen-ops.cpp and then
linked the AArch64 objects with the host linker ("Relocations in generic ELF
(EM: 183)"). The devcontainer and CI have no Eigen, so nothing showed it there.

The rule, lexical over the script: every `make -C` that builds a third-party
package passes both CC= and CXX=, and the aarch64 branch sets cxx from the
cross toolchain. The controls plant a CC-only make and a missing cross cxx.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "build_load_programs.sh"


def logical_lines(text: str):
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        start = i
        line = lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + " " + lines[i].strip()
        i += 1
        yield start + 1, line


def problems_in(text: str) -> list:
    found = []
    makes = 0
    for number, line in logical_lines(text):
        if re.search(r"(^|\s)make\s+-C\s", line):
            makes += 1
            for var in ("CC=", "CXX="):
                if var not in line:
                    found.append(f"build_load_programs.sh:{number}: make -C "
                                 f"without {var}; the host's compiler leaks "
                                 "into the cross build")
    if makes == 0:
        found.append("build_load_programs.sh: no make -C found; the check "
                     "no longer sees the stress-ng build")
    if not re.search(r"^\s*cxx=\$cache/\$toolchain/bin/aarch64-linux-g\+\+\s*$",
                     text, re.M):
        found.append("build_load_programs.sh: the aarch64 branch does not set "
                     "cxx from the cross toolchain")
    return found


def control() -> bool:
    good = ('    cxx=$cache/$toolchain/bin/aarch64-linux-g++\n'
            '    make -C "$src/$p" CC="$cc" CXX="$cxx" \\\n'
            '        CFLAGS="-fPIE" >log 2>&1\n')
    cc_only = good.replace(' CXX="$cxx"', "")
    no_cross = good.replace("    cxx=$cache/$toolchain/bin/aarch64-linux-g++\n",
                            "    cxx=g++\n")
    return (not problems_in(good)
            and len(problems_in(cc_only)) == 1
            and len(problems_in(no_cross)) == 1)


def main() -> int:
    if not control():
        print("FAIL load-programs-cross-toolchain: the control plants a "
              "CC-only cross build and the check did not refuse it",
              file=sys.stderr)
        return 1
    text = SCRIPT.read_text(encoding="utf-8")
    problems = problems_in(text)
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("FAIL load-programs-cross-toolchain: a cross build lets a host "
              "compiler in (#1154)", file=sys.stderr)
        return 1
    report_pass("load-programs-cross-toolchain",
                "every third-party make in build_load_programs.sh names CC and "
                "CXX, and CXX is the cross g++",
                makes=sum(1 for _, line in logical_lines(text)
                          if re.search(r"(^|\s)make\s+-C\s", line)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
