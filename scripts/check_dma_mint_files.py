#!/usr/bin/env python3
"""Hold the fixed-DMA records to a reviewed list of files (#716, #717).

The compiler accepts dma_finish_owned_rx/_tx only in the file that declares
the record, which makes that file the trusted claim that the device is done.
It cannot see whether the file stays small: declaring a record in a large
driver file would widen the trusted code without any compile error. So every
`struct dma_fixed` record is declared in a listed mint file, and a listed file
still declares one. A change to the list is a review of the trusted claim.

Which functions in those files may call a finish builtin, and the observation
each trusts, are rows of scripts/allowed_callers.tsv, read against the
compiler's call-graph table (#1261).
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

MINT_FILES = (
    "kernel/drivers/block/virtio_blk_dma.tkb",
    "kernel/platform/rpi5/usb_xhci_dma.tkb",
)
# A standalone fixture that is never linked into a kernel.
EXCLUDED = (KERNEL / "tests" / "debug_return_abi", KERNEL / "build")

RECORD = re.compile(r"^\s*struct\s+dma_fixed\s+(\w+)", re.M)


def problems_in(files):
    """files: {relative path: text}. Returns a list of problems."""
    problems = []
    for path, text in sorted(files.items()):
        records = RECORD.findall(text)
        if records and path not in MINT_FILES:
            problems.append(
                f"{path} declares fixed DMA record(s) {', '.join(records)} "
                "but is not a listed mint file: the whole file would become "
                "trusted to return device ownership")
    for path in MINT_FILES:
        text = files.get(path)
        if text is None:
            problems.append(f"{path} is a listed mint file that does not exist")
        elif not RECORD.search(text):
            problems.append(f"{path} is a listed mint file that declares no "
                            "fixed DMA record; remove it from the list")
    return problems


def kernel_files():
    files = {}
    for path in KERNEL.rglob("*.tkb"):
        if any(root == path or root in path.parents for root in EXCLUDED):
            continue
        files[str(path.relative_to(ROOT))] = path.read_text(encoding="utf-8")
    return files


def controls(files):
    """Each planted widening must be refused."""
    failures = []
    driver = "kernel/drivers/block/virtio_blk.tkb"
    mint = MINT_FILES[0]
    without = {path: text for path, text in files.items() if path != mint}
    cases = {
        "a record in a driver file":
            {**files, driver: files[driver] +
             "\nstruct dma_fixed Planted { private bytes: [u8; 64]; }\n"},
        "a listed file that declares no record":
            {**files, mint: RECORD.sub("struct planted", files[mint])},
        "a listed file that does not exist": without,
    }
    for label, planted in cases.items():
        if not problems_in(planted):
            failures.append(label)
    return failures, len(cases)


def main():
    files = kernel_files()
    problems = problems_in(files)
    for problem in problems:
        print(f"ERROR\tdma-mint-files: {problem}")
    failures, count = controls(files)
    for label in failures:
        print(f"ERROR\tdma-mint-files: control not refused: {label}")
    if problems or failures:
        print("FAIL dma-mint-files: the trusted fixed-DMA record files changed "
              "without review")
        return 1
    report_pass("dma-mint-files",
                f"{len(MINT_FILES)} mint files hold every fixed DMA record; a "
                "record outside them and a listed file with no record or no "
                "file are each refused", cases=count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
