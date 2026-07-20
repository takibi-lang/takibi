#!/usr/bin/env python3
# Verifies examples/usb_msc_probe/usb_msc_probe.tkb's UART output against a
# real USB Mass Storage drive attached to a Raspberry Pi 3B. No filesystem
# exists at this layer -- like scripts/sdcard_test.py, this validates the
# deterministic byte pattern usb_msc_probe.tkb itself writes and reads back
# (byte i of sector s == (s + i) & 0xFF), read directly from the "MSCDUMP:"
# hex dump line following each sector's PASS/FAIL line. See
# scripts/run_hwtest_rpi3.sh's run_hw_test_rpi3_usb_msc.
import re
import sys


def expected_sector_bytes(sector):
    return bytes((sector + i) & 0xFF for i in range(512))


def main():
    if len(sys.argv) != 2:
        print("usage: usb_msc_test.py <captured_uart_output>", file=sys.stderr)
        return 1
    text = open(sys.argv[1], "r", errors="replace").read()

    ok = True
    if "disk_initialize: OK" not in text:
        print("disk_initialize did not report OK", file=sys.stderr)
        ok = False
    if "disk_status: OK" not in text:
        print("disk_status did not report OK", file=sys.stderr)
        ok = False

    lines = text.splitlines()
    seen_sectors = set()
    for i, line in enumerate(lines):
        m = re.match(r"sector (\d+): (PASS|MISMATCH|FAIL)", line)
        if not m:
            continue
        sector = int(m.group(1))
        status = m.group(2)
        if status != "PASS":
            print(f"sector {sector} reported {status}", file=sys.stderr)
            ok = False
            continue
        if i + 1 >= len(lines) or not lines[i + 1].startswith("MSCDUMP:"):
            print(f"sector {sector}: PASS with no following MSCDUMP line", file=sys.stderr)
            ok = False
            continue
        hexdata = lines[i + 1][len("MSCDUMP:") :].strip()
        try:
            actual = bytes.fromhex(hexdata)
        except ValueError:
            print(f"sector {sector}: MSCDUMP line is not valid hex", file=sys.stderr)
            ok = False
            continue
        expected = expected_sector_bytes(sector)
        if actual != expected:
            print(
                f"sector {sector}: dumped bytes do not match the expected "
                f"pattern (first mismatch at offset "
                f"{next(i for i in range(len(expected)) if actual[i] != expected[i])})",
                file=sys.stderr,
            )
            ok = False
        else:
            seen_sectors.add(sector)

    if len(seen_sectors) == 0:
        print("no sector PASS/MSCDUMP pairs found at all", file=sys.stderr)
        ok = False

    if "usb_msc: ALL PASS" not in text:
        print("usb_msc_probe.tkb itself did not report ALL PASS", file=sys.stderr)
        ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
