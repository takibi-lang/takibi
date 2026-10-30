#!/usr/bin/env python3
"""A program that uses region built-ins without --regions is refused up front.

Before this existed, a build without the flag type-checked an IoHandle and
stopped in code generation with "Unknown named type: IoHandle__T", naming
neither the flag nor a source line (found in the #637 step A land, when two
linux_user fixtures compiled the real virtio-net driver without --regions).
Each sample below must fail with the diagnostic that names the flag, and
must compile once the flag is given.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

DIAGNOSTIC = "compile with --regions"

SAMPLES = {
    "io handle": """
io struct Regs7 { status: u32 at 0x00; }
let mut regs7: IoHandle(Regs7);
fn read7() -> u32 { return regs7.status; }
""",
    "region claim": """
struct N7 { k: usize; }
private region let mut a7: [N7; 4];
fn claim7() {
    let RegionOf(N7)::Taken(r) = region_of(a7) else { RegionOf(N7)::Gone => { return; } };
    region_release(r);
}
""",
    "array of places": """
struct N8 { k: usize; }
fn count8(arr: borrow places(N8)[b, n]) -> usize { return places_count(arr); }
""",
}


def main() -> int:
    compiler = Path(sys.argv[1]).resolve()
    cases = CaseCount()
    failures = []
    with tempfile.TemporaryDirectory(prefix="takibi-regions-flag-") as tmp:
        for name, src in SAMPLES.items():
            source = Path(tmp) / "sample.tkb"
            source.write_text(src, encoding="ascii")
            out = Path(tmp) / "sample.o"
            plain = subprocess.run([str(compiler), "--internal-allow-unused", str(source), "-o", str(out)],
                                   capture_output=True, text=True, check=False)
            cases.note()
            if plain.returncode == 0 or DIAGNOSTIC not in plain.stderr:
                failures.append(f"{name}: without --regions, status "
                                f"{plain.returncode}, stderr {plain.stderr.strip()!r}")
            # The sample's function is its entry, so the unused-function
            # check (on by default, #1027) runs and must skip the built-in
            # region definitions it did not write.
            entry = re.search(r"fn (\w+)", src)[1]
            flagged = subprocess.run([str(compiler), "--external-entry", entry, "--regions",
                                      str(source), "-o", str(out)],
                                     capture_output=True, text=True, check=False)
            cases.note()
            if flagged.returncode != 0:
                failures.append(f"{name}: with --regions it did not compile: "
                                f"{flagged.stderr.strip()!r}")
    if failures:
        for line in failures:
            print("FAIL regions-flag: " + line, file=sys.stderr)
        return 1
    report_pass("regions-flag",
                "region built-ins without --regions are refused up front, "
                "and compile with it", cases=cases.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
