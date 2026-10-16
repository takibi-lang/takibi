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

GOOD = """io struct Rp1XhciRegs {
    usbcmd: u32 at 0x020;
    portsc3: u32 at 0x440;
    iman: u32 at 0x480;
    erstsz: u32 at 0x488;
    erstba_lo: u32 at 0x490;
}
fn f() { rp1_xhci.erstsz = 1; }
"""


def run(source: str) -> subprocess.CompletedProcess[str]:
    CASES.note()
    with tempfile.TemporaryDirectory(prefix="takibi-xhci-check-") as directory:
        fixture = Path(directory) / "fixture.tkb"
        fixture.write_text(source)
        return subprocess.run(
            ["python3", str(CHECKER), str(fixture)], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def expect(source: str, ok: bool, needle: str = "") -> bool:
    result = run(source)
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
        (GOOD.replace("    erstsz: u32 at 0x488;\n", "")
             .replace(".erstsz = 1", ".iman = 1"),
         False, "ERSTSZ is not"),
        (GOOD.replace("rp1_xhci.erstsz = 1;", ""), False, "never written"),
        (GOOD.replace("erstsz: u32 at 0x488", "erstsz: u32 at 0x480"),
         False, "erstsz at 0x480"),
        (GOOD.replace("portsc3: u32 at 0x440", "portsc3: u32 at 0x430"),
         False, "portsc3 at 0x430"),
    ]
    if not all([expect(*case) for case in cases]):
        return 1
    report_pass("xhci-register-offsets-controls",
                "accepts the spec layout and rejects a missing or misplaced "
                "register", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
