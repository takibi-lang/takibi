#!/usr/bin/env python3
"""Controls for rpi5_arp_link_delta.py and its wiring into the RPi5 runner.

GitHub issue #1302. The archive's two ARP facts are only read after a failure,
so a broken parser or a dropped capture would stay silent until the run that
needed them. Both shapes #1297 measured are planted, and the runner is required
to start the capture before its load and to write the delta when it archives.
"""

from pathlib import Path

from pass_line import report_pass
from rpi5_arp_link_delta import delta_line

RUNNER = Path(__file__).resolve().parent / "run_kernel_hwtest_rpi5.sh"
LINK = b"   27.568\trp1 gem: link ready mac=02:00:20:00:00:02\n"


def main() -> int:
    cases = [
        (LINK + b"   28.772\trp1 gem: arp reply ok ip=192.168.20.2\n",
         "link-to-arp-reply: 1.204 s"),
        (LINK + b"   27.568\trp1 gem: arp reply ok ip=192.168.20.2\n",
         "link-to-arp-reply: 0.000 s -- the reply left at once"),
        (LINK + b"   40.000\trp1 gem: arp timeout\n",
         "link-to-arp-reply: link ready, no ARP reply line"),
        (b"   1.000\ttakibi kernel: EL1\n",
         "link-to-arp-reply: no link-ready line"),
    ]
    for data, expected in cases:
        line = delta_line(data)
        if not line.startswith(expected):
            print(f"FAIL rpi5-arp-link-delta: {line!r}, expected {expected!r}")
            return 1
    if "at once" in delta_line(cases[0][0]):
        print("FAIL rpi5-arp-link-delta: a green run read as a spent reply")
        return 1
    text = RUNNER.read_text(encoding="utf-8")
    start = text.find("\narp_capture_start\n")
    load = text.find('scripts/rpi5_jtag_load.sh" "$ELF"')
    if start < 0 or load < 0 or start > load:
        print("FAIL rpi5-arp-link-delta: the runner must start its ARP capture "
              "before its board load")
        return 1
    if 'rpi5_arp_link_delta.py" "$UART_TIMING_LOG"' not in text:
        print("FAIL rpi5-arp-link-delta: the runner must record the delta")
        return 1
    report_pass("rpi5-arp-link-delta",
                "the failure archive's link-to-reply delta reads a green run, a "
                "spent reply, a timeout and no link; the runner is wired to both",
                controls=len(cases))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
