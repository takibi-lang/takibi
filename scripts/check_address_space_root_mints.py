#!/usr/bin/env python3
"""Who may make an AddressSpaceRoot (#693).

Since #693 step 5 an AddressSpaceRoot carries its backing's handle, read
once where the root was made, so the slot and its handle cannot be paired
wrongly and nothing below re-reads the process record. That is only as good
as the places a root is made:

address_space_root_mint is the mint. Its callers are declared below: the
authority-taking makers in kernel/kernel/process.tkb (run lock, owner,
running evidence, full machine stop), root 0's maker, and the backing's
publisher, which wrote the handle it mints with. The transitional maker that
read the handle with no authority (address_space_root_for_slot, 107 calls at
its peak) is gone; adding a maker back is adding a name here.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path("kernel")
MINT = "address_space_root_mint"

ALLOWED = {
    "address_space_backing_publish",
    "address_space_boot_root",
    "scheduled_process_address_space_root_locked",
    "scheduled_process_address_space_root_owned",
    "scheduled_process_address_space_root_stopped",
    "scheduled_process_address_space_root_current",
}

FN_RE = re.compile(r"^(?:private )?(?:inline |noinline )?fn (\w+)\(")
MINT_RE = re.compile(r"\b" + MINT + r"\(")


def main() -> int:
    found = set()
    scanned = 0
    for path in sorted(ROOT.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        scanned += 1
        enclosing = None
        for line in path.read_text().splitlines():
            match = FN_RE.match(line)
            if match:
                enclosing = match.group(1)
                continue
            code = line.split("//", 1)[0]
            if MINT_RE.search(code):
                found.add(enclosing)
    failures = []
    for name in sorted(found - ALLOWED):
        failures.append(f"{name} mints an AddressSpaceRoot and is not declared here")
    for name in sorted(ALLOWED - found):
        failures.append(f"{name} is declared here but no longer mints; remove it")
    if failures:
        for line in failures:
            print("FAIL address-space-root-mints: " + line, file=sys.stderr)
        return 1
    report_pass("address-space-root-mints",
                f"{len(found)} declared mint caller(s) across {scanned} files",
                files=scanned, callers=len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
