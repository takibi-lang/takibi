#!/usr/bin/env python3
"""Drive the terminal read-only UART crash console over QEMU's TCP serial."""

import argparse
import socket
import time

from await_timing import AwaitTiming



def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--await-timing-log",
                        help="JSONL arrival times against the common driver-start timeout")
    # GitHub issue #486: hold the first command until every named line has
    # arrived. The two-core mode's whole claim is that BOTH cores reported,
    # and the console's first prompt belongs to whichever faulted first --
    # asking it for `oops` then would answer about half the machine and pass.
    parser.add_argument("--await-line", action="append", default=[],
                        metavar="TEXT")
    args = parser.parse_args()
    awaited = [text.encode("ascii") for text in args.await_line]

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    started = time.monotonic()
    deadline = started + args.timeout
    commands = [b"oops\n", b"trace\n", b"ps\n", b"proc 1\n"]
    timing = AwaitTiming(args.await_timing_log, started, args.timeout, awaited, commands)
    try:
        return drive(args, awaited, commands, deadline, timing)
    finally:
        timing.finish(time.monotonic())


def drive(args, awaited, commands, deadline, timing):
    connection = None
    while time.monotonic() < deadline:
        try:
            connection = socket.create_connection(("127.0.0.1", args.port), 0.5)
            timing.record("UART connection", True, time.monotonic())
            break
        except OSError:
            time.sleep(0.05)
    if connection is None:
        raise SystemExit("crash-console UART did not accept a connection")

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
            arrived_at = time.monotonic()
            log.write(chunk)
            log.flush()
            received.extend(chunk)
            # The console owner writes its prompt while another core is
            # still rendering, so an awaited line can arrive with `ddb> `
            # inside a word of it. Remove the prompt before asking, exactly
            # as the lane's own assertions do.
            plain = bytes(received).replace(b"ddb> ", b"")
            for i, text in enumerate(awaited):
                if text in plain:
                    timing.record(f"await-line {i + 1}", True, arrived_at)
            found = received.count(b"ddb> ")
            for name in timing.prompt_names[:found]:
                timing.record(name, True, arrived_at)
            if awaited and any(text not in plain for text in awaited):
                continue
            while prompts < found:
                if prompts < len(commands):
                    connection.sendall(commands[prompts])
                prompts += 1
            if prompts >= len(commands) + 1:
                return 0
    plain = bytes(received).replace(b"ddb> ", b"")
    missing = [text.decode("ascii") for text in awaited if text not in plain]
    if missing:
        raise SystemExit(
            "crash-console UART never saw " + ", ".join(repr(m) for m in missing)
            + "; the console was never asked anything, so nothing here says "
              "whether it works")
    raise SystemExit("crash-console UART did not complete all commands")


if __name__ == "__main__":
    raise SystemExit(main())
