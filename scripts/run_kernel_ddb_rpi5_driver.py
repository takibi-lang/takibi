#!/usr/bin/env python3
"""Exercise guarded-fault recovery through a real RPi5 UART BREAK."""

import argparse
import re
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
    resume_command_sent = False
    commands = (b"xkfault\n", b"events\n", b"bt\n", b"continue\n")
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
            if not resume_command_sent and b"ddb: continuing\n" in received:
                uart.write(b"echo ddb-resume-ok\n")
                uart.flush()
                resume_command_sent = True
            normalized = bytes(received).replace(b"\r", b"")
            if b"\n/ # ddb-resume-ok\n/ # " in normalized:
                break

    text = received.decode("ascii", errors="replace")
    if "oops: fail-stop" in text:
        raise SystemExit(
            "RPi5 DDB did not resume after guarded fault "
            "(entered fail-stop crash console)"
        )
    if prompt_count < 2:
        raise SystemExit("RPi5 DDB did not return to a prompt after guarded fault")
    if "ddb: xk fault address=0x0000000800000000" not in text:
        raise SystemExit("RPi5 DDB guarded fault was not reported")
    if "ddb: events cpu=0 count=" not in text:
        raise SystemExit("RPi5 DDB post-fault inspection command did not complete")
    if not re.search(
        r"^ddb: bt source=cpu cpu=[0-9]+ pid=[0-9]+ "
        r"stack=0x[0-9a-f]+\.\.0x[0-9a-f]+$",
        text.replace("\r", ""),
        re.MULTILINE,
    ):
        raise SystemExit("RPi5 DDB did not capture a CPU backtrace root")
    if not re.search(
        r"^ddb: bt frame=0 pc=0x[0-9a-f]+ "
        r"boundary=(exception|user|assembly|assembly-bridge)$",
        text.replace("\r", ""),
        re.MULTILINE,
    ):
        raise SystemExit("RPi5 DDB did not report the interrupted PC boundary")
    if "id=0x0000000000000201" not in text:
        raise SystemExit("RPi5 DDB did not retain the process UART-wake event")
    if "id=0x0000000000000101" not in text:
        raise SystemExit("RPi5 DDB did not retain the platform UART BREAK event")
    if "damaged=0 overwritten=0" not in text:
        raise SystemExit("RPi5 DDB diagnostic ring reported damaged/overwritten data")
    if "ddb: continuing\n" not in text:
        raise SystemExit("RPi5 DDB did not continue after post-fault inspection")
    if (b"\n/ # ddb-resume-ok\n/ # " not in
            bytes(received).replace(b"\r", b"")):
        raise SystemExit("RPi5 workload did not resume after DDB continue")
    print("PASS kernel/rpi5 ddb: guarded fault recovered, inspected, and resumed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
