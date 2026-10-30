#!/usr/bin/env python3
"""scripts/buildcheck_rp1_dma_arena.py rejects what it exists to reject (#1032)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from buildcheck_rp1_dma_arena import declared_objects, problems
from pass_line import report_pass

GOOD = {"rp1_dma_arena_start": (0x600000, 0), "rp1_dma_arena_end": (0x640000, 0),
        "gem_rx_ring": (0x600000, 0x40)}
SOURCE = """private region let mut gem_rx_ring: [GemDesc; 4] align(64);
struct dma_fixed Buf { private bytes: [u8; 64]; }
private let mut buf_one: Buf align(64);
"""


def main():
    cases = [
        (problems(GOOD, {"gem_rx_ring"}) == [], "a good image passes"),
        (problems(GOOD, {"gem_rx_ring", "gc_removed"}) == [], "a gc-removed object passes"),
        (problems({**GOOD, "gem_rx_ring": (0x700000, 0x40)}, {"gem_rx_ring"}) != [],
         "an object outside the arena fails"),
        (problems({**GOOD, "gem_rx_ring": (0x63fff0, 0x40)}, {"gem_rx_ring"}) != [],
         "an object straddling the end fails"),
        (problems({**GOOD, "rp1_dma_arena_end": (0x680000, 0)}, {"gem_rx_ring"}) != [],
         "a size the encoding does not name fails"),
        (problems({**GOOD, "rp1_dma_arena_start": (0x601000, 0),
                   "rp1_dma_arena_end": (0x641000, 0), "gem_rx_ring": (0x601000, 0x40)},
                  {"gem_rx_ring"}) != [], "a misaligned base fails"),
        (problems(GOOD, {"absent"}) != [], "an empty scan fails"),
        (problems({}, {"gem_rx_ring"}) != [], "an image without the arena fails"),
        (declared_objects([SOURCE]) >= {"gem_rx_ring", "buf_one", "xhci_dcbaa"},
         "regions, dma_fixed globals and the raw object are all found"),
    ]
    failed = [name for ok, name in cases if not ok]
    for name in failed:
        print(f"FAIL rp1-dma-arena-controls: {name}")
    if failed:
        return 1
    report_pass("rp1-dma-arena-controls", "the arena check rejects each bad image", controls=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
