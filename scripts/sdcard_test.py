#!/usr/bin/env python3
# Verifies examples/sdcard/sdcard.tkb's UART output against real SDMMC1
# hardware. No filesystem exists at this layer -- unlike fatfs's mtools
# cross-check, this validates the deterministic byte pattern sdcard.tkb
# itself writes and reads back (byte i of sector s == (s + i) & 0xFF),
# read directly from the "SDDUMP:" hex dump line following each sector's
# PASS/FAIL line. See scripts/run_hwtest_ram.sh's run_hw_test_ram_sdcard.
import re
import sys


def expected_sector_bytes(sector):
    return bytes((sector + i) & 0xFF for i in range(512))


def main():
    if len(sys.argv) != 2:
        print("usage: sdcard_test.py <captured_uart_output>", file=sys.stderr)
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
        if i + 1 >= len(lines) or not lines[i + 1].startswith("SDDUMP:"):
            print(f"sector {sector}: PASS with no following SDDUMP line", file=sys.stderr)
            ok = False
            continue
        hexdata = lines[i + 1][len("SDDUMP:") :].strip()
        try:
            actual = bytes.fromhex(hexdata)
        except ValueError:
            print(f"sector {sector}: SDDUMP line is not valid hex", file=sys.stderr)
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
        print("no sector PASS/SDDUMP pairs found at all", file=sys.stderr)
        ok = False

    if "sdcard: ALL PASS" not in text:
        print("sdcard.tkb itself did not report ALL PASS", file=sys.stderr)
        ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
