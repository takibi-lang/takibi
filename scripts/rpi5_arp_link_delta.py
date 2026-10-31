#!/usr/bin/env python3
"""The time from `rp1 gem: link ready` to the kernel's first ARP reply.

GitHub issue #1302. #1297's cause was found from this one number: the kernel
spends its one ARP reply on the first request it holds, so green runs show
about 1.2 s (the host's test has to start) and a run whose reply went to the
host stack's own request shows 0.000 s. Read from the UART driver's host-clock
timing log, whose live lines exist even when a run dies before the dmesg replay.

Usage: rpi5_arp_link_delta.py <uart-timing.log>. Prints one line and exits 0
when the log is absent or readable: this is evidence for a failure archive,
never a verdict.
"""

import re
import sys
from pathlib import Path

TIMED = re.compile(rb"^\s*(\d+\.\d+)\s(.*)$")
LINK = b"rp1 gem: link ready"
REPLY = b"rp1 gem: arp reply ok"
# The lane's own first request follows a link gate that polls the UART log, so
# a reply inside this answered something that was already queued.
SPENT_BELOW_SECONDS = 0.1


def delta_line(data: bytes) -> str:
    link = None
    for raw in data.replace(b"\r", b"").splitlines():
        match = TIMED.match(raw)
        if not match:
            continue
        seconds, text = float(match.group(1)), match.group(2)
        if link is None:
            if LINK in text:
                link = seconds
        elif REPLY in text:
            delta = seconds - link
            note = ""
            if delta < SPENT_BELOW_SECONDS:
                note = (" -- the reply left at once: a request was already "
                        "queued, see arp-capture.log for who asked")
            return f"link-to-arp-reply: {delta:.3f} s{note}"
    if link is None:
        return "link-to-arp-reply: no link-ready line"
    return "link-to-arp-reply: link ready, no ARP reply line"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"link-to-arp-reply: no timing log at {path}")
        return 0
    print(delta_line(path.read_bytes()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
