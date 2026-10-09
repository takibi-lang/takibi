#!/usr/bin/env python3
"""Hold the fixed-DMA mint sites to a reviewed list (GitHub issues #716, #717).

The compiler accepts dma_finish_owned_rx/_tx only in the file that declares
the record, which makes that file the trusted claim that the device is done.
It cannot see whether the file stays small: declaring a record in a large
driver file, or adding a new finishing function to a mint file, would widen
the trusted code without any compile error. This check fixes both, and
the files it names are the ones #637 is to add to its mint-file list:

  * every `struct dma_fixed` record is declared in a listed mint file;
  * every function that calls a finish builtin is listed for its file.

A change to either list is a review of the trusted claim, made here.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

# file -> functions that may return device ownership to the CPU, each with
# the observation it trusts (the file header says the same).
MINT_SITES = {
    "kernel/drivers/block/virtio_blk_dma.tkb": {
        "virtio_blk_receive_settle_used": "used ring advanced",
        "virtio_blk_receive_settle_reset": "status read back zero",
        "virtio_blk_request_settle": "called only after one of the above",
        "virtio_blk_data_settle": "called only after one of the above",
    },
    "kernel/drivers/net/rp1_gem_dma.tkb": {
        "gem_rx_settle_completed": "RX descriptor ownership bit set, read by net_rx_acquire",
    },
    "kernel/platform/rpi5/usb_xhci_dma.tkb": {
        "xhci_receive_configuration": "final Transfer Event or HCHalted",
        "msc_data_receive_once": "final Transfer Event or HCHalted",
        "msc_csw_receive_once": "final Transfer Event or HCHalted",
        "msc_cbw_send_once": "final Transfer Event or HCHalted",
        "msc_data_send_once": "final Transfer Event or HCHalted",
    },
}
# A standalone fixture that is never linked into a kernel.
EXCLUDED = (KERNEL / "tests" / "debug_return_abi", KERNEL / "build")

RECORD = re.compile(r"^\s*struct\s+dma_fixed\s+(\w+)", re.M)
FUNCTION = re.compile(r"^\s*(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)", re.M)
FINISH = re.compile(r"\bdma_finish_owned_(?:rx|tx)\s*\(")


def finishing_functions(text):
    """Names of the functions whose bodies call a finish builtin."""
    found = set()
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(text)]
    for index, (start, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        body = "\n".join(line.split("//", 1)[0]
                         for line in text[start:end].splitlines())
        if FINISH.search(body):
            found.add(name)
    return found


def problems_in(files):
    """files: {relative path: text}. Returns a list of problems."""
    problems = []
    for path, text in sorted(files.items()):
        records = RECORD.findall(text)
        if records and path not in MINT_SITES:
            problems.append(
                f"{path} declares fixed DMA record(s) {', '.join(records)} "
                "but is not a listed mint file: the whole file would become "
                "trusted to return device ownership")
        finishing = finishing_functions(text)
        allowed = set(MINT_SITES.get(path, {}))
        for name in sorted(finishing - allowed):
            problems.append(
                f"{path}: {name} returns device ownership to the CPU but is "
                "not a listed mint site; list it with the observation it trusts")
    for path, sites in MINT_SITES.items():
        text = files.get(path)
        if text is None:
            problems.append(f"{path} is a listed mint file that does not exist")
            continue
        for name in sorted(set(sites) - finishing_functions(text)):
            problems.append(f"{path}: listed mint site {name} no longer "
                            "finishes anything; remove it from the list")
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
    mint = "kernel/drivers/block/virtio_blk_dma.tkb"
    cases = {
        "a record in a driver file":
            {**files, driver: files[driver] +
             "\nstruct dma_fixed Planted { private bytes: [u8; 64]; }\n"},
        "a new finishing function in a mint file":
            {**files, mint: files[mint] +
             "\nfn planted(d: sink *VirtioBlkReceiveDevice) -> *VirtioBlkReceiveCpu {\n"
             "    return dma_finish_owned_rx(d, VirtioBlkReceive);\n}\n"},
        "a stale listed site":
            {**files, mint: files[mint].replace(
                "dma_finish_owned_tx(device, VirtioBlkDataTransmit)",
                "planted(device)")},
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
        print("FAIL dma-mint-files: the trusted fixed-DMA finish sites changed "
              "without review")
        return 1
    sites = sum(len(v) for v in MINT_SITES.values())
    report_pass("dma-mint-files",
                f"{len(MINT_SITES)} mint files, {sites} reviewed finish sites; "
                "a record outside them, an unlisted finisher and a stale "
                "entry are each refused", cases=count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
