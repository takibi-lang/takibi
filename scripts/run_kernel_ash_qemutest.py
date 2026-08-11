#!/usr/bin/env python3
"""Drive the QEMU guest ash shell through its TCP-attached UART."""

import argparse
import socket
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=90.0)
    args = parser.parse_args()

    deadline = time.monotonic() + args.timeout
    connection = None
    while time.monotonic() < deadline:
        try:
            connection = socket.create_connection(("127.0.0.1", args.port), timeout=1.0)
            break
        except OSError:
            time.sleep(0.1)
    if connection is None:
        raise RuntimeError("timed out waiting for the QEMU UART TCP server")

    connection.settimeout(0.5)
    output = bytearray()
    command_sent = False
    try:
        while time.monotonic() < deadline:
            try:
                chunk = connection.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            output.extend(chunk)
            if (not command_sent and
                    b"interactive shell: uart blocked\n" in output):
                connection.sendall(
                    b"busybox; /bin/ls; /bin/ls -a; /bin/ls /bin; "
                    b"echo repl-ok; exit\n"
                )
                command_sent = True
            if (command_sent and
                    b"busybox interactive shell exit: 0" in output and
                    b"concurrency: parent progressed while child uart-blocked" in output):
                break
    finally:
        connection.close()

    text = output.decode("utf-8", errors="replace").replace("\r", "")
    print(text, end="")
    if not command_sent:
        raise RuntimeError("ash readiness marker was not observed")
    required = (
        "BusyBox",
        "repl-ok",
        "busybox interactive shell exit: 0",
        "concurrency: parent progressed while child uart-blocked",
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError("missing UART markers: " + ", ".join(missing))
    if "ls: " in text:
        raise RuntimeError("directory enumeration command reported an ls error")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"FAIL kernel/qemu ash: {error}")
        raise SystemExit(1)
