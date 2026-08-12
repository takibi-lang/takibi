#!/usr/bin/env python3
"""Capture a kernel UART and drive the shared BusyBox ash smoke scenario."""

import argparse
import time

import serial


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True,
                        help="pyserial URL or UART device path")
    parser.add_argument("--log", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--stop-marker", default="resources: pages=0")
    parser.add_argument("--stdin", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--payload-marker",
                        default="concurrency: parent progressed while child uart-blocked")
    parser.add_argument("--payload", default="irqtest")
    parser.add_argument("--ash-only", action="store_true")
    parser.add_argument("--validate-ash", action="store_true")
    args = parser.parse_args()

    commands = [line.rstrip("\n") for line in open(args.stdin, encoding="ascii")
                if line.strip() and not line.startswith("#")]
    expected = [line.rstrip("\n") for line in open(args.expected, encoding="ascii")
                if line.strip() and not line.startswith("#")]
    if not commands:
        raise RuntimeError(f"empty ash input fixture: {args.stdin}")
    if not expected:
        raise RuntimeError(f"empty ash expected fixture: {args.expected}")

    deadline = time.monotonic() + args.timeout
    connection = None
    last_error = None
    while time.monotonic() < deadline:
        try:
            connection = serial.serial_for_url(
                args.port, baudrate=args.baud, timeout=0.1,
                write_timeout=1.0)
            break
        except serial.SerialException as error:
            last_error = error
            time.sleep(0.1)
    if connection is None:
        raise RuntimeError(f"could not open UART {args.port}: {last_error}")

    output = bytearray()
    shell_step = 0
    payload_sent = False
    try:
        with open(args.log, "wb") as capture:
            while time.monotonic() < deadline:
                chunk = connection.read(4096)
                if chunk:
                    output.extend(chunk)
                    capture.write(chunk)
                    capture.flush()

                prompt_count = output.count(b"/ # ")
                if (shell_step == 0 and
                        b"interactive shell: uart blocked\n" in output):
                    connection.write((commands[0] + "\n").encode("ascii"))
                    shell_step = 1
                elif (shell_step > 0 and shell_step < len(commands) and
                      prompt_count >= shell_step + 1):
                    connection.write(
                        (commands[shell_step] + "\n").encode("ascii"))
                    shell_step += 1

                if (not payload_sent and
                        args.payload_marker.encode("ascii") in output):
                    connection.write((args.payload + "\n").encode("ascii"))
                    payload_sent = True

                expected_seen = all(marker.encode("ascii") in output
                                    for marker in expected)
                if args.ash_only:
                    if expected_seen and payload_sent:
                        break
                elif args.stop_marker.encode() in output:
                    break
    finally:
        connection.close()

    text = output.decode("utf-8", errors="replace").replace("\r", "")
    if args.validate_ash:
        missing = [marker for marker in expected if marker not in text]
        if missing:
            raise RuntimeError("missing UART markers: " + ", ".join(missing))
        if any(line.startswith("ls: ") for line in text.splitlines()):
            raise RuntimeError("directory enumeration command reported an ls error")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"FAIL kernel UART driver: {error}")
        raise SystemExit(1)
