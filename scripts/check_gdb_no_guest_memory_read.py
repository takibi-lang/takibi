#!/usr/bin/env python3
"""A gdb check script decides from registers, not from guest memory.

GitHub issue #585: `kernelcheck-affinity-gdb-qemu` identified the probe's
migration by reading the rewound exception frame at `$x0 + 64`. gdb reads
guest memory through the translation the stopped CPU has active -- at that
point the PROCESS's root, which maps the kernel image's identity block but
not every page the allocator hands out for a kernel stack. Whether a boot's
stack landed inside that block was luck, so the read failed about one boot in
ten and the check blamed another process. The fix used the dispatcher's
register argument instead.

Nothing stopped the shape from coming back, and it is silent: the lane is
green on most boots. So a gdb script under scripts/ may not read guest memory
unless the line carries `gdb-memory-read:` with the reason it is safe (for
example, a read made with every CPU stopped in a known translation).

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

SCRIPTS = pathlib.Path("scripts")
READ = re.compile(r"read_memory\s*\(")
# A real import, not the text "import gdb" inside a string -- the controls
# for this check embed exactly that text in their synthetic scripts.
IMPORT = re.compile(r"^import gdb$", re.M)
DECLARED = "gdb-memory-read:"


def main() -> int:
    scanned = 0
    failures = []
    for path in sorted(SCRIPTS.glob("*.py")):
        text = path.read_text()
        if not IMPORT.search(text):
            continue
        scanned += 1
        for number, line in enumerate(text.splitlines(), 1):
            if READ.search(line) and DECLARED not in line:
                failures.append(f"{path}:{number}")
    if failures:
        for where in failures:
            print(f"ERROR\tgdb-no-guest-memory-read: {where} reads guest "
                  "memory from a gdb check. gdb reads through the stopped "
                  "CPU's active translation, which may not map what you "
                  "want (#585); decide from a register, or mark the line "
                  f"`{DECLARED} <why it is safe>`")
        print("FAIL gdb-no-guest-memory-read: "
              f"{len(failures)} undeclared read(s)")
        return 1
    report_pass("gdb-no-guest-memory-read",
                "no gdb check script reads guest memory without a declared "
                "reason", gdb_scripts=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
