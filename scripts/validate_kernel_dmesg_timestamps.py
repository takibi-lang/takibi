#!/usr/bin/env python3
"""Validate the raw BusyBox dmesg transcript without normalizing its time."""

import re
import sys
from pathlib import Path


LINE = re.compile(rb"^\[(\d{6})\.(\d{6})\] (.*)$")


def fail(message: str) -> None:
    raise SystemExit(f"FAIL kernel/dmesg: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("expected one UART log path")
    data = Path(sys.argv[1]).read_bytes().replace(b"\r", b"")
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
    listener = b"virtio net: link ready mac=02:00:20:00:00:02"
    resumed = b"virtio net: tcp handshake echo close reconnect ok"
    if first not in by_text:
        fail("first kernel marker is absent")
    assembled = [item for item in records if item[1].startswith(assembled_prefix)]
    if len(assembled) != 1 or b" detected_mib=" not in assembled[0][1]:
        fail("fragment-assembled memory line is not one complete record")
    if listener not in by_text or resumed not in by_text:
        fail("bounded network retransmission markers are absent")
    elapsed = by_text[resumed] - by_text[listener]
    if elapsed < 3_500_000 or elapsed > 5_500_000:
        fail(f"network interval is {elapsed} us, expected 3.5-5.5 s")
    print(f"PASS kernel/dmesg: monotonic records, assembled lines, delay={elapsed} us")


if __name__ == "__main__":
    main()
