#!/usr/bin/env python3
"""Hold the fixed-DMA records to a reviewed list of files (#716, #717, #567).

Usage: buildcheck_dma_mint_files.py <qemu>.facts/fields.tsv <rpi5>.facts/fields.tsv

The compiler accepts dma_finish_owned_rx/_tx only in the file that declares
the record, which makes that file the trusted claim that the device is done.
It cannot see whether the file stays small: declaring a record in a large
driver file would widen the trusted code without any compile error. So every
`struct dma_fixed` record is declared in a listed mint file, and each listed
file still declares one in some kernel. A change to the list is a review of
the trusted claim.

It reads the compiler's `--facts fields.tsv` of both kernels (each row's
declaring `file` and the struct's `qualifier`, docs/GLOBAL_PROTECTION.md),
not the .tkb text; it replaced scripts/check_dma_mint_files.py's regular
expression (#567). Which functions in those files may call a finish builtin
are rows of scripts/allowed_callers.tsv, read against the call-graph table
(#1261).

Refused: a dma_fixed record declared outside MINT_FILES; a listed file that
does not exist in the tree; a listed file that no kernel's table shows
declaring a record. Negative controls on the real tables: a planted record in
a driver file, and the listed files' records removed, must each be refused.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
MINT_FILES = (
    "kernel/drivers/block/virtio_blk_dma.tkb",
    "kernel/platform/rpi5/usb_xhci_dma.tkb",
)
COLUMNS = ("file", "line", "struct", "field", "hardware", "reads", "writes",
           "qualifier")


def records(path):
    """{(file, struct)} of the dma_fixed records in one fields table."""
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    if not lines or tuple(lines[0].split("\t")) != COLUMNS:
        raise SystemExit(f"FAIL dma-mint-files: {path}: column header is not {COLUMNS}")
    found = set()
    for line in lines[1:]:
        row = dict(zip(COLUMNS, line.split("\t")))
        if row["qualifier"] == "dma_fixed":
            found.add((row["file"], row["struct"]))
    return found


def problems(found):
    result = []
    for file, struct in sorted(found):
        if file not in MINT_FILES:
            result.append(f"{file} declares fixed DMA record {struct} but is not "
                          "a listed mint file: the whole file would become "
                          "trusted to return device ownership")
    declaring = {file for file, _ in found}
    for file in MINT_FILES:
        if not (ROOT / file).exists():
            result.append(f"{file} is a listed mint file that does not exist")
        elif file not in declaring:
            result.append(f"{file} is a listed mint file that declares no fixed "
                          "DMA record in either kernel; remove it from the list")
    return result


def main(argv):
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1])
        return 1
    found = records(argv[1]) | records(argv[2])
    planted = found | {("kernel/drivers/block/virtio_blk.tkb", "Planted")}
    without = {(f, s) for f, s in found if f not in MINT_FILES}
    if not problems(planted) or not problems(without) or not found:
        print("FAIL dma-mint-files: the check's own controls no longer behave")
        return 1
    found_problems = problems(found)
    if found_problems:
        for line in found_problems:
            print(f"ERROR dma-mint-files: {line}")
        print("FAIL dma-mint-files: the trusted fixed-DMA record files changed "
              "without review")
        return 1
    report_pass("dma-mint-files",
                f"{len(MINT_FILES)} mint files hold all {len(found)} fixed DMA "
                "records of both kernels (fields tables); a planted record in a "
                "driver file and listed files with no record are refused",
                records=len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
