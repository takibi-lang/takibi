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
    parser.add_argument("--ash-only", action="store_true")
    parser.add_argument("--validate-ash", action="store_true")
    args = parser.parse_args()

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
                    connection.write(b"x=; /bin/ls\n")
                    shell_step = 1
                elif shell_step == 1 and prompt_count >= 2:
                    connection.write(b"/bin/ls -a\n")
                    shell_step = 2
                elif shell_step == 2 and prompt_count >= 3:
                    connection.write(b"/bin/ls /bin\n")
                    shell_step = 3
                elif shell_step == 3 and prompt_count >= 4:
                    connection.write(b"/bin/ls /many\n")
                    shell_step = 4
                elif shell_step == 4 and prompt_count >= 5:
                    connection.write(b"echo repl-ok\n")
                    shell_step = 5
                elif (shell_step == 5 and b"repl-ok" in output and
                      prompt_count >= 6):
                    connection.write(b"exit\n")
                    shell_step = 6

                if (not payload_sent and
                        b"concurrency: parent progressed while child uart-blocked"
                        in output):
                    connection.write(b"irqtest\n")
                    payload_sent = True

                shell_done = (shell_step == 6 and
                              b"busybox interactive shell exit: 0" in output)
                if args.ash_only:
                    if shell_done and payload_sent:
                        break
                elif args.stop_marker.encode() in output:
                    break
    finally:
        connection.close()

    text = output.decode("utf-8", errors="replace").replace("\r", "")
    if args.validate_ash:
        required = (
            "entry-19",
            "repl-ok",
            "busybox interactive shell exit: 0",
            "concurrency: parent progressed while child uart-blocked",
        )
        missing = [marker for marker in required if marker not in text]
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
