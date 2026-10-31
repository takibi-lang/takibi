#!/usr/bin/env python3
"""The RPi5 lane pins the board's neighbour entry before it resets the board.

GitHub issue #1297. The kernel answers exactly one ARP request, and its RX ring
holds frames from PHY link-up on. A previous run's orphaned TCP sockets make the
host stack ask for the board during that window whenever the entry is not
pinned, so a pin placed after the reset is too late: the lane then fails with
`ARP integration failed` and `rp1 gem: icmp timeout` although nothing is wrong
with the image. Only the board can show the failure itself, and only at one
run's timing, so the order is held here.
"""

from pathlib import Path

from pass_line import report_pass

RUNNER = Path(__file__).resolve().parent / "run_kernel_hwtest_rpi5.sh"
PIN = "sudo ip neigh replace "
LOAD = 'scripts/rpi5_jtag_load.sh" "$ELF"'


def pin_precedes_load(text: str) -> bool:
    lines = text.splitlines()
    pins = [i for i, line in enumerate(lines) if line.lstrip().startswith(PIN)]
    loads = [i for i, line in enumerate(lines) if LOAD in line]
    return len(pins) == 1 and len(loads) == 1 and pins[0] < loads[0]


def main() -> int:
    text = RUNNER.read_text(encoding="utf-8")
    if not pin_precedes_load(text):
        print(f"FAIL rpi5-neigh-pin: {RUNNER.name} must run `{PIN.strip()}` "
              "once, before its one board load (#1297)")
        return 1
    lines = text.splitlines()
    pin_line = next(l for l in lines if l.lstrip().startswith(PIN))
    load_line = next(l for l in lines if LOAD in l)
    planted = {
        "pin after load": text.replace(pin_line, "\0").replace(load_line, pin_line)
                              .replace("\0", load_line),
        "pin removed": text.replace(pin_line, ""),
        "load removed": text.replace(load_line, ""),
    }
    accepted = [name for name, body in planted.items() if pin_precedes_load(body)]
    if accepted:
        print(f"FAIL rpi5-neigh-pin: controls accepted: {', '.join(accepted)}")
        return 1
    report_pass("rpi5-neigh-pin",
                "the board's neighbour entry is pinned before the reset; a later "
                "pin, a missing pin and a missing load are refused",
                controls=len(planted))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
