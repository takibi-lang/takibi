#!/usr/bin/env python3
"""Who may make an AddressSpaceRoot, and how many bare ones are left (#693).

Since #693 step 5 an AddressSpaceRoot carries its backing's handle, read
once where the root was made, so the slot and its handle cannot be paired
wrongly and nothing below re-reads the process record. That is only as good
as the places a root is made:

- address_space_root_mint is the mint. Its callers are declared below: the
  authority-taking makers in kernel/kernel/process.tkb (owner, running
  evidence), root 0's maker, the backing's publisher (which wrote the handle
  it mints with), and the transitional bare maker.
- address_space_root_for_slot is that transitional maker: it reads the
  handle with no authority, as every access did before. Its calls must EQUAL
  the budget below; going under is progress, so lower the budget in the
  same commit.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path("kernel")
MINT = "address_space_root_mint"
BARE = "address_space_root_for_slot"
BARE_BUDGET = 107

ALLOWED = {
    "address_space_backing_publish",
    "address_space_boot_root",
    "address_space_root_for_slot",
    "scheduled_process_address_space_root_owned",
    "scheduled_process_address_space_root_running",
}

FN_RE = re.compile(r"^(?:private )?fn (\w+)\(")
MINT_RE = re.compile(r"\b" + MINT + r"\(")
BARE_RE = re.compile(r"\b" + BARE + r"\(")


def main() -> int:
    found = set()
    bare = 0
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
            bare += len(BARE_RE.findall(code))
    failures = []
    for name in sorted(found - ALLOWED):
        failures.append(f"{name} mints an AddressSpaceRoot and is not declared here")
    for name in sorted(ALLOWED - found):
        failures.append(f"{name} is declared here but no longer mints; remove it")
    if bare > BARE_BUDGET:
        failures.append(f"{bare} call(s) of {BARE}, over the budget of "
                        f"{BARE_BUDGET}; make the root from an authority instead")
    if bare < BARE_BUDGET:
        failures.append(f"{bare} call(s) of {BARE}, under the budget of "
                        f"{BARE_BUDGET}; lower BARE_BUDGET in {__file__} to {bare}")
    if failures:
        for line in failures:
            print("FAIL address-space-root-mints: " + line, file=sys.stderr)
        return 1
    report_pass("address-space-root-mints",
                f"{len(found)} declared mint caller(s) and {bare} bare "
                f"{BARE} call(s), equal to its budget, across {scanned} files",
                files=scanned, callers=len(found), bare=bare)
    return 0


if __name__ == "__main__":
    sys.exit(main())
