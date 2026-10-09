#!/usr/bin/env python3
"""A widened race window exists only in its overlay, never in kernel/.

GitHub issue #615: scripts/build_qemu_race_window.py widens a named window by
inserting a spin into a copy of one kernel file, and only the two race-window
kernels are built from that copy. The ordinary QEMU, RPi5 and debug kernels
are built from kernel/ itself, so a spin that never reaches kernel/ never
reaches them. This check holds that line: no tracked kernel source may carry
the spin's marker or its loop variable.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import sys

from pass_line import report_pass

KERNEL = pathlib.Path("kernel")
# The spin's own comment and its loop variable, as the builder writes them.
MARKERS = ("scripts/build_qemu_race_window.py)", "race_window_start", "delayed_probe_entry",
           "probe-ticks: missing-peer controls complete", "world_stop_resume_control",
           "signal_round_control", "peer_tick_stamp_control")


def main() -> int:
    scanned = 0
    failures = []
    for path in sorted(KERNEL.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        scanned += 1
        text = path.read_text(encoding="ascii", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            if any(marker in line for marker in MARKERS):
                failures.append(f"{path}:{number}")
    if failures:
        for where in failures:
            print(f"ERROR\trace-window-overlay-only: {where} carries a race-"
                  "window spin in the ordinary source, so every kernel built "
                  "from it would carry it too (#615); widen windows only in "
                  "scripts/build_qemu_race_window.py's overlay")
        print(f"FAIL race-window-overlay-only: {len(failures)} spin(s) in kernel/")
        return 1
    report_pass("race-window-overlay-only",
                "no kernel source carries a race-window spin; only the "
                "overlay kernels do", kernel_files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
