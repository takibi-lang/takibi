#!/usr/bin/env python3
"""Exercise UART-wake and BREAK diagnostic events on a running RPi5 kernel."""

import argparse
import time

import serial


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    deadline = time.monotonic() + args.timeout
    received = bytearray()
    prompt_count = 0
    commands = (b"events\n", b"continue\n")
    with serial.Serial(args.port, 115200, timeout=0.25) as uart, open(
        args.log, "ab"
    ) as log:
        uart.write(b"\n")
        uart.flush()
        uart.send_break(0.25)
        while time.monotonic() < deadline:
            chunk = uart.read(4096)
            if not chunk:
                continue
            received.extend(chunk)
            log.write(chunk)
            log.flush()
            found = received.count(b"ddb> ")
            while prompt_count < found:
                if prompt_count < len(commands):
                    uart.write(commands[prompt_count])
                    uart.flush()
                prompt_count += 1
            if b"ddb: continuing\n" in received:
                break
        else:
            raise SystemExit("RPi5 DDB BREAK/events/continue sequence timed out")

    text = received.decode("ascii", errors="replace")
    if "id=0x0000000000000201" not in text:
        raise SystemExit("RPi5 DDB did not retain the process UART-wake event")
    if "id=0x0000000000000101" not in text:
        raise SystemExit("RPi5 DDB did not retain the platform UART BREAK event")
    if "damaged=0 overwritten=0" not in text:
        raise SystemExit("RPi5 DDB diagnostic ring reported damaged/overwritten data")
    print("PASS kernel/rpi5 ddb: UART wake and BREAK events inspected and resumed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
