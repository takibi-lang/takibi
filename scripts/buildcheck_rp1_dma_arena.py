#!/usr/bin/env python3
"""Every RP1 DMA object lies inside the arena the PCIe inbound window opens.

GitHub issue #1032 (B'): pcie2_dma_inbound_setup opens the window over
rp1_dma_arena_start..rp1_dma_arena_end only, and link.ld places objects there
by name. An object added to a driver and not to that list would link fine and
fail only as a device error on the board, so the list is checked here against
the drivers' own declarations: every `region let mut` and dma_fixed global in
RP1's driver files, plus the raw xhci_dcbaa.
"""

import re
import subprocess
import sys
from pathlib import Path

from pass_line import report_pass

REPO_ROOT = Path(__file__).resolve().parent.parent
DRIVER_GLOBS = ("kernel/drivers/net/rp1_gem*.tkb", "kernel/platform/rpi5/usb_xhci*.tkb")
RAW_OBJECTS = ("xhci_dcbaa",)
ARENA_BYTES = 0x40000


def declared_objects(texts):
    names = set(RAW_OBJECTS)
    for text in texts:
        names.update(re.findall(r"^\s*(?:private\s+)?region\s+let\s+mut\s+(\w+)\s*:", text, re.M))
        for record in re.findall(r"^\s*struct\s+dma_fixed\s+(\w+)", text, re.M):
            names.update(re.findall(
                rf"^\s*(?:private\s+)?let\s+mut\s+(\w+)\s*:\s*{record}\b", text, re.M))
    return names


def problems(symbols, names):
    """symbols: {name: (address, size)}. Returns a list of failure reasons."""
    start = symbols.get("rp1_dma_arena_start", (None, 0))[0]
    end = symbols.get("rp1_dma_arena_end", (None, 0))[0]
    if start is None or end is None:
        return ["rp1_dma_arena_start/end not in the image"]
    found = []
    if end - start != ARENA_BYTES:
        found.append(f"arena is {end - start:#x} bytes, pcie2_dma_inbound_setup encodes "
                     f"{ARENA_BYTES:#x}")
    if start % ARENA_BYTES != 0:
        found.append(f"arena base {start:#x} is not aligned to its size")
    present = 0
    for name in sorted(names):
        if name not in symbols:
            continue  # removed by --gc-sections: no device can be given it
        present += 1
        address, size = symbols[name]
        if address < start or address + size > end:
            found.append(f"{name} at {address:#x}+{size:#x} is outside the arena; "
                         f"add .bss.{name} to link.ld")
    if present == 0:
        found.append("no RP1 DMA object in the image: the declaration scan found nothing")
    return found


def read_symbols(elf):
    listing = subprocess.run(["llvm-nm-19", "-S", str(elf)], check=True,
                             capture_output=True, text=True, timeout=30).stdout
    symbols = {}
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 4:
            symbols[fields[3]] = (int(fields[0], 16), int(fields[1], 16))
        elif len(fields) == 3:
            symbols[fields[2]] = (int(fields[0], 16), 0)
    return symbols


def main(argv):
    elf = argv[1]
    texts = [path.read_text(encoding="ascii") for pattern in DRIVER_GLOBS
             for path in sorted(REPO_ROOT.glob(pattern))]
    names = declared_objects(texts)
    found = problems(read_symbols(elf), names)
    for reason in found:
        print(f"FAIL rp1-dma-arena: {elf}: {reason}")
    if found:
        return 1
    report_pass("rp1-dma-arena", f"{elf}: declared RP1 DMA objects are inside the window",
                objects=len(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
