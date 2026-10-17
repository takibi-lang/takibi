#!/usr/bin/env python3
"""Positive and negative controls for check_register_offsets.py (#805).

In-process: each control plants one defect in the real kernel sources and
calls problems(), so no child process is spawned (check_fast_gate_no_spawn).
"""

from __future__ import annotations

import sys

from pass_line import CaseCount, report_pass
from check_register_offsets import kernel_sources, problems


CASES = CaseCount()
GEM = "kernel/drivers/net/rp1_gem.tkb"
GIC = "kernel/arch/arm64/kernel/gicv2.tkb"
PCIE = "kernel/platform/rpi5/pcie.tkb"


def planted(base: dict[str, str], path: str, old: str, new: str) -> dict[str, str]:
    if old not in base[path]:
        raise SystemExit(f"FAIL register-offsets-controls: {path} no longer "
                         f"holds {old!r}; update the control")
    changed = dict(base)
    changed[path] = base[path].replace(old, new, 1)
    return changed


def expect(sources: dict[str, str], ok: bool, needle: str = "") -> bool:
    CASES.note()
    failures, _ = problems(sources)
    text = "\n".join(failures)
    if (not failures) != ok or needle not in text:
        print(f"FAIL register-offsets-controls: expected ok={ok} with {needle!r}:")
        print(text)
        return False
    return True


def main() -> int:
    base = kernel_sources()
    cases = [
        (base, True, ""),
        # The PolarFire web summary's 0x4C4 (CBS_IDLESLOPE_Q_B in the
        # vendor header), in place of TBQPH's 0x4C8.
        (planted(base, GEM, "tbqph: u32 at 0x4C8", "tbqph: u32 at 0x4C4"),
         False, "Rp1GemRegs.tbqph at 0x4c4"),
        # The #733 shape: a queue-1 bank register declared as queue 0's.
        (planted(base, GEM, "    tbqph: u32 at 0x4C8;\n",
                 "    tbqph: u32 at 0x4C8;\n    tbqp_q1: u32 at 0x440;\n"),
         False, "Rp1GemRegs.tbqp_q1 is not in its offset table"),
        (planted(base, GIC, "icfgr: [u32; 64] at 0xC00", "icfgr: [u32; 128] at 0xC00"),
         False, "GicV2Distributor.icfgr has 128 elements"),
        (planted(base, GIC, "itargetsr: [u8; 1024] at 0x800", "itargetsr: u32 at 0x800"),
         False, "GicV2Distributor.itargetsr has no elements"),
        (planted(base, PCIE, "hard_debug: u32 at 0x4304", "hard_debug: u32 at 0x4204"),
         False, "Pcie2Regs.hard_debug at 0x4204"),
        (planted(base, PCIE, "io struct BcmResetRegs {",
                 "io struct BcmNewRegs {\n    x: u32 at 0x0;\n}\nio struct BcmResetRegs {"),
         False, "io struct BcmNewRegs has no sourced offset table"),
        (planted(base, PCIE, "io struct PcieRescalRegs", "io struct PcieRescal"),
         False, "offset table PcieRescalRegs names no io struct"),
        (planted(base, PCIE, "    start: u32 at 0x00;\n",
                 "    start: u32 at 0x00;\n    status2: u32 @ 0x0C;\n"),
         False, "cannot read the field line"),
    ]
    if not all([expect(*case) for case in cases]):
        return 1
    report_pass("register-offsets-controls",
                "accepts the kernel's io structs and rejects a misplaced, "
                "unlisted, resized or unreadable field and an unsourced or "
                "vanished block", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
