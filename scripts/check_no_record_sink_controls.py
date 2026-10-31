#!/usr/bin/env python3
"""Controls for check_no_record_sink.py, in both directions: the two shapes it
exists for are refused, and their honest neighbours are not."""

import sys

from check_no_record_sink import violations
from pass_line import report_pass

POOL = "private let mut rec_pool: RegionPool(Rec);\n"

REFUSED = {
    "a static payload": POOL + "private let mut rec_absent: Rec;\n",
    "a static payload array": POOL + "private let mut rec_spare: [Rec; 2];\n",
    "the boot root on one line":
        "match x { L::Absent => { return address_space_boot_root(); } }\n",
    "the boot root in a longer arm":
        "match x { R::Stale => {\n note();\n return address_space_boot_root();\n } }\n",
}
ACCEPTED = {
    "the pool itself": POOL,
    "an unrelated static": POOL + "private let mut count: AtomicWord;\n",
    "the boot root outside an absent arm":
        "match x { R::Kernel => { return address_space_boot_root(); } }\n",
    "an absent arm with a dead root":
        "match x { L::Absent => { return address_space_root_mint(slot, none); } }\n",
}


def main() -> int:
    failed = 0
    for name, text in REFUSED.items():
        if not violations({"k.tkb": text}):
            print(f"FAIL no-record-sink-controls: not refused: {name}", file=sys.stderr)
            failed += 1
    for name, text in ACCEPTED.items():
        if violations({"k.tkb": text}):
            print(f"FAIL no-record-sink-controls: refused: {name}", file=sys.stderr)
            failed += 1
    if failed:
        return 1
    report_pass("no-record-sink-controls",
                f"{len(REFUSED)} planted shapes refused, {len(ACCEPTED)} neighbours accepted",
                refused=len(REFUSED), accepted=len(ACCEPTED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
