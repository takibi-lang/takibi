#!/usr/bin/env python3
"""Send a real QEMU serial BREAK, inspect through DDB, then prove resume."""

import argparse
import json
import socket
import time


def connect(port: int, deadline: float) -> socket.socket:
    while time.monotonic() < deadline:
        try:
            return socket.create_connection(("127.0.0.1", port), 0.5)
        except OSError:
            time.sleep(0.05)
    raise SystemExit(f"tcp/{port} did not accept a connection")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial-port", type=int, required=True)
    parser.add_argument("--qmp-port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    deadline = time.monotonic() + args.timeout

    serial = connect(args.serial_port, deadline)
    serial.settimeout(0.25)
    received = bytearray()
    break_sent = False
    prompt_count = 0
    commands = [b"oops\n", b"regs\n", b"trace\n", b"continue\n"]

    with serial, open(args.log, "wb") as log:
        while time.monotonic() < deadline:
            try:
                chunk = serial.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            received.extend(chunk)
            log.write(chunk)
            log.flush()

            if not break_sent and b"distro stack: argc=3 argv auxv ready\n" in received:
                with connect(args.qmp_port, deadline) as qmp:
                    qmp_file = qmp.makefile("rwb", buffering=0)
                    greeting = json.loads(qmp_file.readline())
                    if "QMP" not in greeting:
                        raise SystemExit("QMP greeting did not appear")
                    qmp_file.write(b'{"execute":"qmp_capabilities"}\n')
                    if "return" not in json.loads(qmp_file.readline()):
                        raise SystemExit("QMP capability negotiation failed")
                    qmp_file.write(
                        b'{"execute":"chardev-send-break",'
                        b'"arguments":{"id":"debug_uart"}}\n')
                    if "return" not in json.loads(qmp_file.readline()):
                        raise SystemExit("QMP could not send the serial BREAK")
                break_sent = True

            found = received.count(b"ddb> ")
            while prompt_count < found:
                if prompt_count < len(commands):
                    serial.sendall(commands[prompt_count])
                prompt_count += 1

            if (prompt_count >= len(commands) and
                    b"ddb: continuing\n" in received and
                    b"init: ash bootstrap\n" in received):
                return 0

    raise SystemExit("DDB BREAK/inspect/continue sequence did not complete")


if __name__ == "__main__":
    raise SystemExit(main())
