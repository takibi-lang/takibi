#!/usr/bin/env python3
"""Name /etc/init.sh's own failure before the lane's downstream verdicts.

GitHub issue #1209. When init.sh exits nonzero part way through, every later
fixture it would have run is simply missing, and the first verdict a lane
prints is about one of them -- in the #1086 land, "BusyBox dmesg emitted no
timestamped records" on every lane, while the cause was init.sh stopping at
/bin/peer-mutate. This reads the UART capture for init's exit line of a
/bin/sh child with a nonzero code and prints the init.sh line that names the
step it stopped at (the last line before the exit that ends in "failed" or
"FAIL", else the line just before it).

It changes no verdict: it prints and exits 0, so the lane's own checks still
decide. A capture whose init.sh exited 0, or never exited, prints nothing.

Usage: kernel_init_failure.py UART_LOG
"""

import re
import sys

EXIT_RE = re.compile(r'exit: init child pid=(\d+) image="/bin/sh" code=(\d+)')
FAILED_RE = re.compile(r"(failed|FAIL)\s*$")


def init_failure(lines):
    """(code, step line) of the first nonzero init.sh exit, or None."""
    for index, line in enumerate(lines):
        match = EXIT_RE.search(line)
        if not match or match.group(2) == "0":
            continue
        step = None
        for earlier in reversed(lines[max(0, index - 40):index]):
            if FAILED_RE.search(earlier.strip()):
                step = earlier.strip()
                break
        if step is None and index > 0:
            step = lines[index - 1].strip()
        return int(match.group(2)), step or "(no line before the exit)"
    return None


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        text = open(argv[1], "rb").read().decode("latin-1").replace("\r", "")
    except OSError as error:
        print(f"kernel/init.sh: cannot read {argv[1]}: {error}", file=sys.stderr)
        return 0
    found = init_failure(text.splitlines())
    if found is not None:
        code, step = found
        print(f"FAIL kernel/init.sh: /etc/init.sh exited {code} after {step!r}; "
              "the verdicts below are about the steps it never reached")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
