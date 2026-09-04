#!/usr/bin/env python3
"""Drive and validate the deliberate DDB software breakpoint on RPi5."""

import argparse
from pathlib import Path
import re
import time

import serial


def write_line(uart: serial.Serial, line: bytes) -> None:
    for byte in line + b"\n":
        uart.write(bytes((byte,)))
        time.sleep(0.01)
    uart.flush()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--generated-start", type=lambda value: int(value, 0),
                        required=True)
    parser.add_argument("--generated-end", type=lambda value: int(value, 0),
                        required=True)
    parser.add_argument("--snapshot-ready-file", required=True)
    parser.add_argument("--snapshot-release-file", required=True)
    parser.add_argument("--timeout", type=float, default=180.0)
    args = parser.parse_args()

    deadline = time.monotonic() + args.timeout
    ready_file = Path(args.snapshot_ready_file)
    release_file = Path(args.snapshot_release_file)
    ready_file.unlink(missing_ok=True)
    release_file.unlink(missing_ok=True)
    received = bytearray()
    prompt_count = 0
    commands = (
        b"intr", b"current", b"sched", b"vm", b"fds", b"ps", b"proc 1",
        b"trace", b"events", b"bt", b"continue",
    )
    shell_probe_sent = False

    with serial.Serial(args.port, 115200, timeout=0.25) as uart, open(
        args.log, "wb"
    ) as log:
        while time.monotonic() < deadline:
            chunk = uart.read(4096)
            if chunk:
                received.extend(chunk)
                log.write(chunk)
                log.flush()

            found = received.count(b"ddb> ")
            if found > prompt_count:
                ready_file.touch()
                if not release_file.exists():
                    deadline = time.monotonic() + args.timeout
                    continue
            while prompt_count < found:
                if prompt_count < len(commands):
                    write_line(uart, commands[prompt_count])
                prompt_count += 1

            normalized = bytes(received).replace(b"\r", b"")
            if (not shell_probe_sent and b"ddb: continuing\n" in normalized
                    and b"/ # " in normalized):
                write_line(uart, b"echo ddb-software-resume-ok")
                shell_probe_sent = True
            if (shell_probe_sent
                    and b"\nddb-software-resume-ok\n/ # " in normalized):
                break

    text = bytes(received).replace(b"\r", b"").decode(
        "ascii", errors="replace"
    )
    if not re.search(
        r"^ddb: intr cpu=[0-9]+ entry=brk source=21579 ", text, re.MULTILINE
    ):
        raise SystemExit("RPi5 DDB did not enter through reserved software BRK")
    if not re.search(
        r"^ddb: bt frame=0 pc=0x[0-9a-f]+ boundary=assembly-bridge$",
        text, re.MULTILINE
    ):
        raise SystemExit("RPi5 DDB backtrace root was not the assembly bridge")

    compiler_pcs = [
        int(match.group(1), 16)
        for match in re.finditer(
            r"^ddb: bt frame=[1-9][0-9]* pc=0x([0-9a-f]+) "
            r"fp=0x[0-9a-f]+$",
            text,
            re.MULTILINE,
        )
    ]
    if not compiler_pcs:
        raise SystemExit(
            "RPi5 DDB backtrace was root-only; no compiler frame was reported"
        )
    outside = [
        pc for pc in compiler_pcs
        if not args.generated_start <= pc < args.generated_end
    ]
    if outside:
        raise SystemExit(
            "RPi5 DDB compiler frame outside .text.takibi: "
            + ", ".join(f"0x{pc:x}" for pc in outside)
        )
    if not re.search(
        r"^ddb: bt frame=[1-9][0-9]* pc=0x[0-9a-f]+ "
        r"fp=0x[0-9a-f]+ boundary=assembly$",
        text, re.MULTILINE
    ):
        raise SystemExit("RPi5 DDB did not report the terminal assembly frame")
    if not re.search(
        r"^ddb: bt stop=assembly-boundary fp=0x[0-9a-f]+$",
        text, re.MULTILINE
    ):
        raise SystemExit("RPi5 DDB did not stop at the assembly boundary")
    if "ddb: bt stop=user-boundary" in text:
        raise SystemExit("RPi5 software-BRK lane accepted a user-boundary walk")
    if "ddb: continuing\n" not in text:
        raise SystemExit("RPi5 DDB did not continue after the compiler walk")
    if "\nddb-software-resume-ok\n/ # " not in text:
        raise SystemExit("RPi5 shell did not resume in the same boot")

    print(
        "PASS kernel/rpi5 ddb: software BRK walked "
        f"{len(compiler_pcs)} compiler frame(s) and resumed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
