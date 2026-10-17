#!/usr/bin/env python3
"""Check the xHCI register layout against the xHCI 1.2 specification.

GitHub issue #754: interrupter 0's ERST size was programmed through a write
to IMAN (+0x00) instead of ERSTSZ (+0x08), because the register layout had
no ERSTSZ field and the write named the wrong one. The io struct already
makes every access go through a named field, so this check anchors the names
to the specification: each field named after an xHCI register must sit at
that register's offset, and a layout that programs an Event Ring Segment
Table (ERSTBA) must declare ERSTSZ and write it in the same file.

GitHub issue #804: the two block bases (the operational block at CAPLENGTH
and interrupter 0 at RTSOFF + 0x20) are not fixed here. They are read from
the struct itself (usbcmd and iman), which is what bring-up compares against
the controller's CAPLENGTH and RTSOFF before it writes anything. This check
requires that comparison to exist and to run before the controller is
halted, so the struct is the single source of the bases and the board is
their authority.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from pass_line import report_pass


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FILE = ROOT / "kernel/platform/rpi5/usb_xhci.tkb"
STRUCT = "Rp1XhciRegs"

# xHCI 1.2 section 5.3 (capability registers, fixed offsets).
CAPABILITY = {"caplength_hciversion": 0x00, "rtsoff": 0x18}
STAGES = "usb_disk_initialize_stages"
CHECK_CALL = "xhci_check_capability_layout()"
FIRST_WRITE = "xhci_halt_and_reset()"


def spec(operational: int, interrupter0: int) -> dict[str, int]:
    """Section 5.4 (operational) and 5.5.2 (interrupter register set)."""
    return {
        "usbcmd": operational + 0x00,
        "usbsts": operational + 0x04,
        "pagesize": operational + 0x08,
        "dnctrl": operational + 0x14,
        "crcr_lo": operational + 0x18,
        "crcr_hi": operational + 0x1C,
        "dcbaap_lo": operational + 0x30,
        "dcbaap_hi": operational + 0x34,
        "config": operational + 0x38,
        "iman": interrupter0 + 0x00,
        "imod": interrupter0 + 0x04,
        "erstsz": interrupter0 + 0x08,
        "erstba_lo": interrupter0 + 0x10,
        "erstba_hi": interrupter0 + 0x14,
        "erdp_lo": interrupter0 + 0x18,
        "erdp_hi": interrupter0 + 0x1C,
    } | CAPABILITY


PORTSC = re.compile(r"portsc(\d+)$")
FIELD = re.compile(r"^\s*(\w+)\s*:\s*[^;]*?\bat\s+(0x[0-9A-Fa-f]+|\d+)\s*;", re.M)


def layout(text: str) -> dict[str, int] | None:
    match = re.search(r"io\s+struct\s+" + STRUCT + r"\s*\{(.*?)\n\}", text, re.S)
    if match is None:
        return None
    return {name: int(offset, 0) for name, offset in FIELD.findall(match.group(1))}


def check(text: str, fields: dict[str, int]) -> list[str]:
    failures = [f"{name} is not declared; bring-up checks the block bases "
                "with it" for name in ("usbcmd", "iman", *CAPABILITY)
                if name not in fields]
    if failures:
        return failures
    operational = fields["usbcmd"]
    interrupter0 = fields["iman"]
    if interrupter0 < 0x20 or (interrupter0 - 0x20) % 0x20 != 0:
        failures.append(f"iman at {interrupter0:#x} is not RTSOFF + 0x20 for "
                        "a 32-byte aligned RTSOFF")
    stages = re.search(r"fn\s+" + STAGES + r"\b.*?\n\}", text, re.S)
    if stages is None:
        failures.append(f"no {STAGES} to check the capability read in")
    else:
        body = stages.group(0)
        read = body.find(CHECK_CALL)
        write = body.find(FIRST_WRITE)
        if read < 0:
            failures.append(f"{STAGES} never calls {CHECK_CALL}")
        elif 0 <= write < read:
            failures.append(f"{STAGES} calls {FIRST_WRITE} before {CHECK_CALL}")
    expected_offsets = spec(operational, interrupter0)
    for name, offset in fields.items():
        expected = expected_offsets.get(name)
        port = PORTSC.match(name)
        if port is not None:
            expected = operational + 0x400 + 0x10 * (int(port.group(1)) - 1)
        if expected is not None and offset != expected:
            failures.append(f"{name} at {offset:#x}, the specification puts it "
                            f"at {expected:#x}")
    if "erstba_lo" in fields:
        if "erstsz" not in fields:
            failures.append("ERSTBA is declared but ERSTSZ is not")
        elif not re.search(r"\.erstsz\s*=[^=]", text):
            failures.append("ERSTBA is programmed but ERSTSZ is never written")
    return failures


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_FILE
    text = path.read_text()
    fields = layout(text)
    if fields is None:
        print(f"FAIL xhci-register-offsets: {path}: no io struct {STRUCT}")
        return 1
    failures = check(text, fields)
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
