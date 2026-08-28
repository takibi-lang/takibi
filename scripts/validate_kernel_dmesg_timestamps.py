#!/usr/bin/env python3
"""Validate the raw BusyBox dmesg transcript without normalizing its time."""

import argparse
import re
from pathlib import Path


LINE = re.compile(rb"^\[(\d{6})\.(\d{6})\] (.*)$")


def fail(message: str) -> None:
    raise SystemExit(f"FAIL kernel/dmesg: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("uart_log", type=Path)
    parser.add_argument("--platform", choices=("qemu", "rpi5"), default="qemu")
    args = parser.parse_args()
    data = args.uart_log.read_bytes().replace(b"\r", b"")
    records: list[tuple[int, bytes]] = []
    for line in data.splitlines():
        match = LINE.match(line)
        if match:
            timestamp = int(match.group(1)) * 1_000_000 + int(match.group(2))
            records.append((timestamp, match.group(3)))
    if not records:
        fail("BusyBox dmesg emitted no timestamped records")
    if any(right[0] < left[0] for left, right in zip(records, records[1:])):
        fail("record timestamps are not monotonic")

    by_text = {text: timestamp for timestamp, text in records}
    first = b"takibi kernel: EL1"
    assembled_prefix = b"memory: base_bytes="
    if args.platform == "qemu":
        listener = b"virtio net: link ready mac=02:00:20:00:00:02"
        resumed = b"virtio net: tcp handshake echo close reconnect ok"
        minimum_delay = 3_500_000
        maximum_delay = 5_500_000
    else:
        listener = b"rp1 gem: link ready mac=02:00:20:00:00:02"
        resumed = b"rp1 gem: tcp handshake echo close reconnect ok"
        minimum_delay = 5_000_000
        maximum_delay = 9_000_000
    if first not in by_text:
        fail("first kernel marker is absent")
    assembled = [item for item in records if item[1].startswith(assembled_prefix)]
    if len(assembled) != 1 or b" detected_mib=" not in assembled[0][1]:
        fail("fragment-assembled memory line is not one complete record")
    if listener not in by_text or resumed not in by_text:
        fail("bounded network retransmission markers are absent")
    elapsed = by_text[resumed] - by_text[listener]
    if elapsed < minimum_delay or elapsed > maximum_delay:
        fail(
            f"{args.platform} network interval is {elapsed} us, expected "
            f"{minimum_delay / 1_000_000:.1f}-{maximum_delay / 1_000_000:.1f} s"
        )
    print(
        f"PASS kernel/{args.platform} dmesg: monotonic records, "
        f"assembled lines, delay={elapsed} us"
    )


if __name__ == "__main__":
    main()
