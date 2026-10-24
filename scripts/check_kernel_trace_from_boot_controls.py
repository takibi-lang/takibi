#!/usr/bin/env python3
"""Controls for scripts/kernel_trace_from_boot.py's verdict (GitHub issue #965).

The verify step is what stops kernelcheck-qemu-debug-main passing with the
trace silently off. Each case below is a GDB transcript it must refuse; the
last is the one it must accept. The boot-level negative control (a trace-on
boot that cannot pass must fail the lane) is
scripts/run_kernel_trace_from_boot_control.sh.
"""

from __future__ import annotations

import sys

from kernel_trace_from_boot import judge
from pass_line import report_pass

REFUSED = {
    "no state line": "Remote connection closed\n",
    "boot switch off": "trace-from-boot state boot=0 live=1 sequence=40\n",
    "live switch off": "trace-from-boot state boot=1 live=0 sequence=40\n",
    "empty ring": "trace-from-boot state boot=1 live=1 sequence=0\n",
}
ACCEPTED = "trace-from-boot state boot=1 live=1 sequence=4096\n"


def main() -> int:
    failures = [name for name, output in REFUSED.items() if not judge(output)]
    if judge(ACCEPTED):
        failures.append("accepted case refused: " + judge(ACCEPTED))
    if failures:
        print("FAIL kernel-trace-from-boot-controls: " + "; ".join(failures),
              file=sys.stderr)
        return 1
    report_pass("kernel-trace-from-boot-controls",
                "off or empty trace states refused, an on trace accepted",
                cases=len(REFUSED) + 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
