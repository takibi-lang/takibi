#!/usr/bin/env python3
"""Wait for a line in a growing log, with a no-progress budget (#1415).

    await_log_line.py --log PATH --pattern TEXT [--quiet 10] [--cap 180]

Waits until TEXT appears in PATH. The wait ends without it only after
--quiet seconds in which the log did not grow (any growth restarts that
budget, as #1365 made the FDT boots wait), or at --cap seconds overall, so a
guest that is still printing under host load is late, not stopped. Exit 0
when the line arrived; 1 otherwise, printing why on stdout ("no output for
N s" or "still printing at the N s cap"), for the runner's failure line.
"""

import argparse
import os
import sys
import time


def wait(path, pattern, quiet, cap, clock=time.monotonic, sleep=time.sleep,
         step=0.1):
    """(arrived, reason) for one wait; [clock] and [sleep] for the controls."""
    needle = pattern.encode()
    started = clock()
    size = -1
    quiet_until = started + quiet
    while True:
        try:
            with open(path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            data = b""
        if needle in data:
            return True, "arrived"
        now = clock()
        if len(data) != size:
            size = len(data)
            quiet_until = now + quiet
        if now >= started + cap:
            return False, f"still printing at the {cap:g} s cap"
        if now >= quiet_until:
            return False, f"no output for {quiet:g} s"
        sleep(step)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", required=True)
    parser.add_argument("--pattern", required=True)
    parser.add_argument("--quiet", type=float, default=10.0)
    parser.add_argument("--cap", type=float, default=180.0)
    args = parser.parse_args(argv[1:])
    arrived, reason = wait(args.log, args.pattern, args.quiet, args.cap)
    if not arrived:
        print(reason)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
