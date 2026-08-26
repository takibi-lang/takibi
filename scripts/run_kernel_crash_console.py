#!/usr/bin/env python3
"""Drive the terminal read-only UART crash console over QEMU's TCP serial."""

import argparse
import socket
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    deadline = time.monotonic() + args.timeout
    connection = None
    while time.monotonic() < deadline:
        try:
            connection = socket.create_connection(("127.0.0.1", args.port), 0.5)
            break
        except OSError:
            time.sleep(0.05)
    if connection is None:
        raise SystemExit("crash-console UART did not accept a connection")

    commands = [b"oops\n", b"trace\n", b"ps\n", b"proc 1\n"]
    received = bytearray()
    prompts = 0
    with connection, open(args.log, "wb") as log:
        connection.settimeout(0.25)
        while time.monotonic() < deadline:
            try:
                chunk = connection.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            log.write(chunk)
            log.flush()
            received.extend(chunk)
            found = received.count(b"ddb> ")
            while prompts < found:
                if prompts < len(commands):
                    connection.sendall(commands[prompts])
                prompts += 1
            if prompts >= len(commands) + 1:
                return 0
    raise SystemExit("crash-console UART did not complete all commands")


if __name__ == "__main__":
    raise SystemExit(main())
