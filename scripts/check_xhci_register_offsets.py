#!/usr/bin/env python3
"""Check the xHCI register layout against the xHCI 1.2 specification.

GitHub issue #754: interrupter 0's ERST size was programmed through a write
to IMAN (+0x00) instead of ERSTSZ (+0x08), because the register layout had
no ERSTSZ field and the write named the wrong one. The io struct already
makes every access go through a named field, so this check anchors the names
to the specification: each field named after an xHCI register must sit at
that register's offset, and a layout that programs an Event Ring Segment
Table (ERSTBA) must declare ERSTSZ and write it in the same file.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from pass_line import report_pass


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FILE = ROOT / "kernel/platform/rpi5/usb_xhci.tkb"
STRUCT = "Rp1XhciRegs"

# RP1 usbhost0: CAPLENGTH is 0x20 and RTSOFF is 0x460, so the operational
# block starts at +0x20 and interrupter 0 at RTSOFF + 0x20 = +0x480.
OPERATIONAL = 0x20
INTERRUPTER0 = 0x480

# xHCI 1.2 section 5.4 (operational) and 5.5.2 (interrupter register set).
SPEC = {
    "usbcmd": OPERATIONAL + 0x00,
    "usbsts": OPERATIONAL + 0x04,
    "pagesize": OPERATIONAL + 0x08,
    "dnctrl": OPERATIONAL + 0x14,
    "crcr_lo": OPERATIONAL + 0x18,
    "crcr_hi": OPERATIONAL + 0x1C,
    "dcbaap_lo": OPERATIONAL + 0x30,
    "dcbaap_hi": OPERATIONAL + 0x34,
    "config": OPERATIONAL + 0x38,
    "iman": INTERRUPTER0 + 0x00,
    "imod": INTERRUPTER0 + 0x04,
    "erstsz": INTERRUPTER0 + 0x08,
    "erstba_lo": INTERRUPTER0 + 0x10,
    "erstba_hi": INTERRUPTER0 + 0x14,
    "erdp_lo": INTERRUPTER0 + 0x18,
    "erdp_hi": INTERRUPTER0 + 0x1C,
}
PORTSC = re.compile(r"portsc(\d+)$")
FIELD = re.compile(r"^\s*(\w+)\s*:\s*[^;]*?\bat\s+(0x[0-9A-Fa-f]+|\d+)\s*;", re.M)


def layout(text: str) -> dict[str, int] | None:
    match = re.search(r"io\s+struct\s+" + STRUCT + r"\s*\{(.*?)\n\}", text, re.S)
    if match is None:
        return None
    return {name: int(offset, 0) for name, offset in FIELD.findall(match.group(1))}


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_FILE
    text = path.read_text()
    fields = layout(text)
    if fields is None:
        print(f"FAIL xhci-register-offsets: {path}: no io struct {STRUCT}")
        return 1
    failures: list[str] = []
    for name, offset in fields.items():
        expected = SPEC.get(name)
        port = PORTSC.match(name)
        if port is not None:
            expected = OPERATIONAL + 0x400 + 0x10 * (int(port.group(1)) - 1)
        if expected is not None and offset != expected:
            failures.append(f"{name} at {offset:#x}, the specification puts it "
                            f"at {expected:#x}")
    if "erstba_lo" in fields:
        if "erstsz" not in fields:
            failures.append("ERSTBA is declared but ERSTSZ is not")
        elif not re.search(r"\.erstsz\s*=[^=]", text):
            failures.append("ERSTBA is programmed but ERSTSZ is never written")
    if failures:
        print(f"FAIL xhci-register-offsets: {path}:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    report_pass("xhci-register-offsets",
                f"{len(fields)} {STRUCT} fields match the xHCI specification",
                fields=len(fields))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
