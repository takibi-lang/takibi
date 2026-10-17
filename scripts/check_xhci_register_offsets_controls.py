#!/usr/bin/env python3
"""Positive and negative controls for check_xhci_register_offsets.py."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_xhci_register_offsets.py"

CASES = CaseCount()

GOOD = """io struct XhciCapabilityRegs {
    caplength_hciversion: u32 at 0x00;
    dboff: u32 at 0x14;
    rtsoff: u32 at 0x18;
}
io struct XhciOperationalRegs {
    usbcmd: u32 at 0x00;
    ports: [u32; 1020] at 0x400;
}
io struct XhciRuntimeRegs {
    iman: u32 at 0x20;
    erstsz: u32 at 0x28;
    erstba_lo: u32 at 0x30;
}
io struct XhciDoorbellRegs {
    doorbell: [u32; 256] at 0x00;
}
"""
DRIVER = "fn f() { rp1_xhci_rt.erstsz = 1; }\n"


def run(regs: str, driver: str) -> subprocess.CompletedProcess[str]:
    CASES.note()
    with tempfile.TemporaryDirectory(prefix="takibi-xhci-check-") as directory:
        regs_path = Path(directory) / "regs.tkb"
        driver_path = Path(directory) / "driver.tkb"
        regs_path.write_text(regs)
        driver_path.write_text(driver)
        return subprocess.run(
            ["python3", str(CHECKER), str(regs_path), str(driver_path)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def expect(regs: str, ok: bool, needle: str = "", driver: str = DRIVER) -> bool:
    result = run(regs, driver)
    if (result.returncode == 0) != ok or needle not in result.stdout:
        print(f"FAIL xhci-register-offsets-controls: expected ok={ok} "
              f"with {needle!r}:")
        print(result.stdout, end="")
        return False
    return True


def main() -> int:
    cases = [
        (GOOD, True, "PASS"),
        # The #754 shape: no ERSTSZ field, the write goes to IMAN.
        (GOOD.replace("    erstsz: u32 at 0x28;\n", ""), False, "ERSTSZ is not",
         DRIVER.replace(".erstsz", ".iman")),
        (GOOD, False, "never written", "fn f() { }\n"),
        (GOOD.replace("erstsz: u32 at 0x28", "erstsz: u32 at 0x20"),
         False, "XhciRuntimeRegs.erstsz at 0x20"),
        (GOOD.replace("ports: [u32; 1020] at 0x400", "ports: [u32; 1020] at 0x410"),
         False, "XhciOperationalRegs.ports at 0x410"),
        # GitHub issue #804: an offset copied from one controller's absolute
        # layout (interrupter 0 at +0x480) instead of its block's.
        (GOOD.replace("iman: u32 at 0x20", "iman: u32 at 0x480"),
         False, "XhciRuntimeRegs.iman at 0x480"),
        (GOOD.replace("rtsoff: u32 at 0x18", "rtsoff: u32 at 0x1C"),
         False, "XhciCapabilityRegs.rtsoff at 0x1c"),
        # An array field: its `[T; N]` type holds a semicolon.
        (GOOD.replace("doorbell: [u32; 256] at 0x00", "doorbell: [u32; 256] at 0x500"),
         False, "XhciDoorbellRegs.doorbell at 0x500"),
        (GOOD.replace("io struct XhciDoorbellRegs", "io struct XhciDoorbells"),
         False, "no io struct XhciDoorbellRegs"),
        (GOOD.replace("    usbcmd: u32 at 0x00;\n",
                      "    usbcmd: u32 at 0x00;\n    portsc3: u32 at 0x440;\n"),
         False, "portsc3 is not an xHCI 1.2 register"),
    ]
    if not all([expect(*case) for case in cases]):
        return 1
    report_pass("xhci-register-offsets-controls",
                "accepts the per-block spec layout and rejects a missing, "
                "misplaced or unknown register or block", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
