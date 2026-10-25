#!/usr/bin/env python3
"""Controls for reboot_hung_core.py, the #980 hung-core reboot verdict.

A transcript whose stop reached the masked core passes; one whose stop left
it out, one that completed after its spin ended, one where the probe's
reboot returned (the pre-#980 EAGAIN), and one with no mask line are refused.
"""

import sys

from pass_line import report_pass
from reboot_hung_core import hung_core_stop_problems

INITIATOR = b"\nsystem stop: initiator cpu=1\n"
MARKER = b"system stop: restart (all cores parked)\n"


def stop(mask: str, spin: str) -> bytes:
    return (INITIATOR + f"system stop: mask=0x{mask} masked-spin={spin}\n"
            .encode() + MARKER)


CASES = (
    ("complete with the hung core", stop("000000000000000d", "cpu2"), True),
    ("mask without the hung core", stop("0000000000000009", "cpu2"), False),
    ("spin already over", stop("000000000000000d", "none"), False),
    ("another core spinning", stop("000000000000000d", "cpu3"), False),
    ("reboot returned EAGAIN",
     b"\nhang-core: reboot returned while cpu 2 spun masked\n", False),
    ("no mask line", INITIATOR + MARKER, False),
)


def main() -> int:
    failed = []
    for name, text, accepted in CASES:
        if (not hung_core_stop_problems(text)) != accepted:
            failed.append(name)
    for name in failed:
        print(f"ERROR\treboot-hung-core-controls: {name}: wrong verdict")
    if failed:
        print("FAIL reboot-hung-core-controls")
        return 1
    report_pass("reboot-hung-core-controls",
                f"{len(CASES)} planted transcripts, each given its verdict",
                runs=len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
