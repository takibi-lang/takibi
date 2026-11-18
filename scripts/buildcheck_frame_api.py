#!/usr/bin/env python3
"""Check public frame exports using the compiler's source signature facts."""
import csv
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
MINT_LIST = ROOT / "kernel" / "RAW_MINT_FILES"

# (file, function) -> (issue that retires it, why it exports an address and
# the capability it moves to). Measured 2026-10-25, not guessed: ten raw
# returns, of which fdt_blob_base retired in the same commit (its only
# caller, linux_user/fdt, passes the fixture's own address now). None of
# the sixteen files has a public `*T` return.
EXPORT = "#1017"  # the frame's named API: a typed export instead of usize
RATCHET = {
    # The trap frame's address, read by the exception-entry assembly ABI
    # (gicv2 returns it to the vector) and by the stack-guard and DDB
    # reporters; FrameRef already carries it.
    ("kernel/arch/arm64/kernel/frame_ref.tkb", "frame_ref_address"):
        (EXPORT, "assembly ABI and reporter export of the trap frame"),
    ("kernel/arch/arm64/kernel/frame_ref.tkb", "frame_any_address"):
        (EXPORT, "assembly ABI export: the frame sp the vector restores"),
    # Device bus addresses: written to a descriptor, never dereferenced.
    # One mint for every device-visible address (#1162).
    ("kernel/drivers/dma_address.tkb", "virtio_span_address"):
        (EXPORT, "bus-address export of a DMA span to the device"),
    ("kernel/drivers/dma_address.tkb", "rp1_span_bus_address"):
        (EXPORT, "bus-address export of a DMA span to the device"),
    ("kernel/drivers/dma_address.tkb", "dma_span_cpu_address"):
        (EXPORT, "CPU physical address of a DMA span, for a DDB cache read"),
    # Physical addresses that callers turn back into access: these move to
    # owners.
    ("kernel/arch/arm64/mm/mmu.tkb", "mmu_user_l3_physical"):
        ("#637", "an L3 table's physical address; moves to a page-table owner"),
    ("kernel/boot/fdt.tkb", "fdt_memory_first_base"):
        ("#637", "a RAM bank base; moves to a memory-map region"),
}

ADDRESS_NAME = re.compile(
    r"address|physical|phys|_base\b|_base_|_ptr\b|pointer|_pa\b|_sp\b")
RAW_POINTER = re.compile(r"(?:^|[\s(,\[<])\*")
USIZE = re.compile(r"\busize\b")

COLUMNS = ["file", "line", "name", "private", "returns"]


def read_signatures(path):
    with Path(path).open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != COLUMNS:
            raise ValueError(f"{path}: invalid source signature header")
        for row in reader:
            if None in row or not all(row.values()) or row["private"] not in ("true", "false"):
                raise ValueError(f"{path}: malformed source signature row")
            yield row["file"], row["name"], row["private"] == "true", row["returns"]


def problems(signatures, files, ratchet):
    failures = []
    covered = set()
    raw = set()
    for path, name, private, returned in signatures:
        if path not in files:
            continue
        covered.add(path)
        if private:
            continue
        if RAW_POINTER.search(returned) or (USIZE.search(returned) and ADDRESS_NAME.search(name)):
            raw.add((path, name))
            if (path, name) not in ratchet:
                failures.append(f"{path}: public fn {name} returns raw authority: {returned}")
    failures.extend(f"{path}: mint file missing from both signature tables"
                    for path in sorted(files - covered))
    failures.extend(f"{path}: stale frame API ratchet entry {name}"
                    for path, name in sorted(set(ratchet) - raw))
    return failures


def controls():
    path = "control.tkb"
    files = {path}
    good = [(path, "existing_address", False, "usize")]
    ratchet = {(path, "existing_address"): ("#637", "control")}
    assert not problems(good, files, ratchet)
    for name, ty in [("unwrap", "*u8"), ("unwrap", "*io u32"),
                     ("unwrap", "(bool,*u8)"), ("unwrap", "*align(8)u64"),
                     ("physical_address", "{0..<8 as usize}"),
                     ("generic_buffer_address", "*T")]:
        assert problems(good + [(path, name, False, ty)], files, ratchet), (name, ty)
    assert not problems(good + [(path, "private_pointer", True, "*u8"),
                                (path, "count", False, "usize")], files, ratchet)
    assert problems([], files, ratchet)
    assert problems([(path, "existing_address", True, "usize")], files, ratchet)


def main(argv):
    if len(argv) != 2:
        raise ValueError("usage: buildcheck_frame_api.py QEMU_SIGNATURES RPI5_SIGNATURES")
    files = {line.strip() for line in MINT_LIST.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.strip().startswith("#")}
    signatures = set(row for table in argv for row in read_signatures(table))
    failures = problems(sorted(signatures), files, RATCHET)
    for failure in failures:
        print(f"FAIL frame-api: {failure}", file=sys.stderr)
    if failures:
        return 1
    controls()
    report_pass("frame-api", f"{len(files)} mint files; {len(RATCHET)} reviewed raw exports; controls passed", files=len(files))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        sys.exit(f"FAIL frame-api: {error}")
