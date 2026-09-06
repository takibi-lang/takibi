#!/usr/bin/env python3
"""Measure what the maintained kernel's TCP path sustains, over one transfer.

GitHub issue #280 is parked on one number: how fast the kernel can move bytes
over Ethernet, because that is what decides whether a network-delivered rootfs
is worth building. Everything else about that decision is measured. SWD is at
its ceiling -- 187.4 KiB/s at 30 MHz on this probe, with 40 MHz and above
failing to transfer -- and the board already absorbs 29.8 MB/s over USB mass
storage during an ordinary boot. What nothing measured is the kernel's own
wire.

Nothing in the tree measured it because the tools that look like they do are
about a different stack: `scripts/profile_tcp_burst_load.py` drives
`examples/tcp_echo`, and the maintained kernel's own HTTP fixtures serve files
too small to time.

This needs no kernel change. The maintained kernel runs BusyBox `httpd -f -p
8080 -h /`, so the rootfs is already reachable over HTTP, and `/bin/
busybox.static` is about 1.09 MB of it -- large enough that the transfer, not
the round trip, is what is being timed.

## What this does NOT establish

Whether the rate is bound by the wire, by the kernel's CPU, or by BusyBox.
Answering that needs a profiling interval around the transfer, and the
kernel's `profile: cpu` accounting is emitted for the `busy-pair` workload
only -- a second workload is a kernel-side change. So read this as a floor on
what the path can do, and as the number #280 needs to compare against
187.4 KiB/s, not as a verdict on where the time goes.

It also measures a stack that has had no optimization pass. A low number here
is a lower bound on the achievable rate, not a ceiling on it.

Usage:
  measure_kernel_tcp_throughput.py --host 192.168.20.2 [--port 8080]
                                   [--path /bin/busybox.static]
                                   [--interface enp5s0] [--json FILE]

Expects a board already serving: `make kernelcheck-rpi5` has one up while its
interactive HTTPd checks run, and `make kernelsh-rpi5` plus `httpd-serve.sh &`
gives one by hand. This does not manage the board, so it cannot leave one in a
state somebody else has to clean up.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from net_link_wait import wait_until_reachable

DEFAULT_PATH = "/bin/busybox.static"


def fetch(url: str, interface: str | None, timeout: float) -> tuple[int, float]:
    """Return (bytes received, seconds), or raise on a transport failure."""
    command = ["curl", "--silent", "--show-error", "--fail", "--noproxy", "*",
               "--output", "/dev/null", "--connect-timeout", "5",
               "--max-time", str(timeout),
               "--write-out", "%{size_download} %{time_total}"]
    if interface:
        command += ["--interface", interface]
    command.append(url)
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        # curl's exit 7 is "could not connect", which is the shape the
        # reachability wait below is allowed to retry. Everything else is
        # reported as itself.
        raise OSError(
            7 if result.returncode == 7 else 0,
            f"curl exited {result.returncode}: {result.stderr.strip()[:300]}")
    size_text, _, time_text = result.stdout.strip().partition(" ")
    try:
        return int(size_text), float(time_text)
    except ValueError:
        raise OSError(0, f"curl reported {result.stdout.strip()!r}, not a "
                         "size and a time") from None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--path", action="append", dest="paths",
                        help="repeatable; several sizes show whether the "
                             "rate is constant or falls with length")
    parser.add_argument("--interface")
    parser.add_argument("--repeat", type=int, default=3,
                        help="transfers to time; the spread is the point")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--commit", default="")
    args = parser.parse_args()

    paths = args.paths or [DEFAULT_PATH]
    measured, failed = [], False
    first = True
    for path in paths:
        url = f"http://{args.host}:{args.port}{path}"
        runs = []
        for _ in range(args.repeat):
            try:
                # Only the very first transfer waits for reachability: after
                # it the board has answered, so a later refusal is a real one
                # and must not be retried into.
                if first:
                    size, seconds = wait_until_reachable(
                        lambda: fetch(url, args.interface, args.timeout),
                        seconds=20.0, label=url)
                    first = False
                else:
                    size, seconds = fetch(url, args.interface, args.timeout)
            except OSError as error:
                print(f"FAIL kernel-tcp-throughput: {url} did not transfer: "
                      f"{error}", file=sys.stderr)
                failed = True
                break
            if size <= 0 or seconds <= 0:
                print(f"FAIL kernel-tcp-throughput: {url} reported {size} "
                      f"bytes in {seconds} s, which measures nothing",
                      file=sys.stderr)
                failed = True
                break
            runs.append({"bytes": size, "seconds": seconds,
                         "bytes_per_second": size / seconds})
        if not runs:
            continue
        sizes = {run["bytes"] for run in runs}
        if len(sizes) != 1:
            print(f"FAIL kernel-tcp-throughput: {url} returned {sorted(sizes)}"
                  " bytes across its transfers, so they are not the same "
                  "measurement", file=sys.stderr)
            failed = True
            continue
        rates = sorted(run["bytes_per_second"] for run in runs)
        measured.append({"url": url, "path": path, "bytes": runs[0]["bytes"],
                         "runs": runs,
                         "slowest_bytes_per_second": rates[0],
                         "fastest_bytes_per_second": rates[-1]})
        print(f"  {path}: {runs[0]['bytes']} bytes, "
              f"{rates[0] / 1024:.0f}-{rates[-1] / 1024:.0f} KiB/s "
              f"over {len(runs)} transfer(s)")

    if args.json and measured:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({
            "host": args.host, "port": args.port, "commit": args.commit,
            "measured": measured,
        }, indent=2) + "\n", encoding="ascii")

    if failed or not measured:
        return 1
    slowest = min(m["slowest_bytes_per_second"] for m in measured)
    fastest = max(m["fastest_bytes_per_second"] for m in measured)
    print(f"PASS kernel-tcp-throughput: {len(measured)} path(s), "
          f"{slowest / 1024:.0f}-{fastest / 1024:.0f} KiB/s "
          f"({slowest / 1e6:.2f}-{fastest / 1e6:.2f} MB/s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
