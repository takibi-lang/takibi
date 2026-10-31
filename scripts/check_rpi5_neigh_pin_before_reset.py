#!/usr/bin/env python3
"""The RPi5 lanes pin the board's neighbour entry before they load the kernel.

GitHub issue #1297. The kernel answers exactly one ARP request, and its RX ring
holds frames from PHY link-up on. A previous run's orphaned TCP sockets make the
host stack ask for the board during that window whenever the entry is not
pinned, so a pin placed after the load is too late: the lane then fails with
`ARP integration failed` and `rp1 gem: icmp timeout` although nothing is wrong
with the image. Only the board can show the failure itself, and only at one
run's timing, so the order is held here, for every runner that both loads an
image with that one reply and has a host peer asking for it (#1303).
"""

import re
from pathlib import Path

from pass_line import report_pass

SCRIPTS = Path(__file__).resolve().parent
RUNNERS = ("run_kernel_hwtest_rpi5.sh", "run_kernel_shell_rpi5.sh")
PIN = re.compile(r"^\s*(if )?sudo( -n)? ip neigh replace ")
LOAD = 'scripts/rpi5_jtag_load.sh" "$ELF"'


def pin_precedes_load(text: str) -> bool:
    lines = text.splitlines()
    pins = [i for i, line in enumerate(lines) if PIN.match(line)]
    loads = [i for i, line in enumerate(lines) if LOAD in line]
    return len(pins) == 1 and len(loads) == 1 and pins[0] < loads[0]


def main() -> int:
    controls = 0
    for runner in RUNNERS:
        text = (SCRIPTS / runner).read_text(encoding="utf-8")
        if not pin_precedes_load(text):
            print(f"FAIL rpi5-neigh-pin: {runner} must run `sudo ip neigh "
                  "replace` once, before its one board load (#1297)")
            return 1
        lines = text.splitlines()
        pin_line = next(l for l in lines if PIN.match(l))
        load_line = next(l for l in lines if LOAD in l)
        planted = {
            "pin after load": text.replace(pin_line, "\0").replace(load_line, pin_line)
                                  .replace("\0", load_line),
            "pin removed": text.replace(pin_line, ""),
            "load removed": text.replace(load_line, ""),
        }
        accepted = [name for name, body in planted.items() if pin_precedes_load(body)]
        if accepted:
            print(f"FAIL rpi5-neigh-pin: {runner}: controls accepted: "
                  f"{', '.join(accepted)}")
            return 1
        controls += len(planted)
    report_pass("rpi5-neigh-pin",
                "both RPi5 runners pin the board's neighbour entry before the "
                "load; a later pin, a missing pin and a missing load are refused",
                controls=controls)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
