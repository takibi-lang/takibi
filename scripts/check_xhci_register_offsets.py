#!/usr/bin/env python3
"""Check the xHCI register blocks against the xHCI 1.2 specification.

GitHub issue #754: interrupter 0's ERST size was programmed through a write
to IMAN (+0x00) instead of ERSTSZ (+0x08), because the register layout had
no ERSTSZ field and the write named the wrong one. The io structs make every
access go through a named field, so this check anchors the names to the
specification: each field named after an xHCI register must sit at that
register's offset inside its block, and a layout that programs an Event Ring
Segment Table (ERSTBA) must declare ERSTSZ and the driver must write it.

GitHub issues #804 and #806: each register block is its own io struct whose
offsets are relative to the block's base, and the bases come from the
controller (CAPLENGTH, RTSOFF, DBOFF) at attach time. So this check holds no
controller-specific value; it compares each block's table with the
specification and requires every block to be declared.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGS = ROOT / "kernel/drivers/usb/xhci_regs.tkb"
DEFAULT_DRIVER = ROOT / "kernel/platform/rpi5/usb_xhci.tkb"

# xHCI 1.2 section 5.3 (capability), 5.4 (operational; port register sets
# at 0x400 + 0x10 * (n - 1)), 5.5.2 (interrupter 0 at runtime + 0x20) and
# 5.6 (doorbell array at the doorbell base).
SPEC = {
    "XhciCapabilityRegs": {
        "caplength_hciversion": 0x00,
        "hcsparams1": 0x04,
        "hcsparams2": 0x08,
        "hcsparams3": 0x0C,
        "hccparams1": 0x10,
        "dboff": 0x14,
        "rtsoff": 0x18,
        "hccparams2": 0x1C,
    },
    "XhciOperationalRegs": {
        "usbcmd": 0x00,
        "usbsts": 0x04,
        "pagesize": 0x08,
        "dnctrl": 0x14,
        "crcr_lo": 0x18,
        "crcr_hi": 0x1C,
        "dcbaap_lo": 0x30,
        "dcbaap_hi": 0x34,
        "config": 0x38,
        "ports": 0x400,
    },
    "XhciRuntimeRegs": {
        "mfindex": 0x00,
        "iman": 0x20,
        "imod": 0x24,
        "erstsz": 0x28,
        "erstba_lo": 0x30,
        "erstba_hi": 0x34,
        "erdp_lo": 0x38,
        "erdp_hi": 0x3C,
    },
    "XhciDoorbellRegs": {
        "doorbell": 0x00,
    },
}
# The type may be an array, whose `[T; N]` holds a semicolon (#804: the
# doorbell array went unchecked before this allowed it).
FIELD = re.compile(r"^\s*(\w+)\s*:\s*(?:\[[^\]]*\]|[^;\[])*?\bat\s+"
                   r"(0x[0-9A-Fa-f]+|\d+)\s*;", re.M)


def layout(text: str, struct: str) -> dict[str, int] | None:
    match = re.search(r"io\s+struct\s+" + struct + r"\s*\{(.*?)\n\}", text, re.S)
    if match is None:
        return None
    return {name: int(offset, 0) for name, offset in FIELD.findall(match.group(1))}


def check(regs: str, driver: str) -> tuple[list[str], int]:
    failures: list[str] = []
    count = 0
    # A field or a write that survives only in a comment is neither declared
    # nor written (GitHub issue #815).
    regs, driver = code_only(regs), code_only(driver)
    blocks: dict[str, dict[str, int]] = {}
    for struct, table in SPEC.items():
        fields = layout(regs, struct)
        if fields is None:
            failures.append(f"no io struct {struct}")
            continue
        blocks[struct] = fields
        for name, offset in fields.items():
            count += 1
            expected = table.get(name)
            if expected is None:
                failures.append(f"{struct}.{name} is not an xHCI 1.2 register "
                                "this check knows; add it to SPEC from the "
                                "specification")
            elif offset != expected:
                failures.append(f"{struct}.{name} at {offset:#x}, the "
                                f"specification puts it at {expected:#x}")
    runtime = blocks.get("XhciRuntimeRegs", {})
    if "erstba_lo" in runtime:
        if "erstsz" not in runtime:
            failures.append("ERSTBA is declared but ERSTSZ is not")
        elif not re.search(r"\.erstsz\s*=[^=]", driver):
            failures.append("ERSTBA is programmed but ERSTSZ is never written")
    return failures, count


def main() -> int:
    regs_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REGS
    driver_path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_DRIVER
    failures, count = check(regs_path.read_text(), driver_path.read_text())
    if failures:
        print(f"FAIL xhci-register-offsets: {regs_path}:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    report_pass("xhci-register-offsets",
                f"{count} fields of {len(SPEC)} xHCI register blocks match "
                "the specification", fields=count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
