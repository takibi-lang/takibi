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
    parser.add_argument("--break-source", choices=("uart", "software"), default="uart")
    parser.add_argument("--kernel-address", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    deadline = time.monotonic() + args.timeout

    serial = connect(args.serial_port, deadline)
    serial.settimeout(0.25)
    received = bytearray()
    break_sent = args.break_source == "software"
    wake_byte_sent = args.break_source == "software"
    prompt_count = 0
    commands = [
        b"oops\n", b"regs\n", b"intr\n", b"sched\n",
        b"current\n", b"vm\n", b"fds\n",
        b"ps\n", b"proc 1\n",
        b"trace\n", b"events\n",
        f"xk {args.kernel_address} 2\n".encode("ascii"),
        b"xk ffffffffffffffff 2\n", b"xk 0 0\n",
        b"xk 1000000000 1\n", b"xkfault\n",
        f"xp {args.kernel_address} 2\n".encode("ascii"),
        b"xp 1000000000 1\n",
        b"xu 1 80000000 2\n", b"xu 1 80000fff 2\n",
        b"xu 1 ffffffffffffffff 2\n", b"xu 1 80000000 65\n",
        b"xu 999999 80000000 1\n", b"xu 1 70000000 1\n",
        b"continue\n",
    ]

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

            # Drive the two producers in an evidence-backed order rather than
            # guessing how much host sleep lets the guest run. The marker says
            # the interactive shell has published its UART wait. Submit the
            # ordinary byte first and QEMU's out-of-band BREAK second; the
            # event-ring assertions below prove that the guest actually
            # recorded wake before BREAK.
            if (not wake_byte_sent and
                    b"interactive shell: uart blocked\n" in received):
                serial.sendall(b"\n")
                wake_byte_sent = True

            if wake_byte_sent and not break_sent:
                with connect(args.qmp_port, deadline) as qmp:
                    qmp_file = qmp.makefile("rwb", buffering=0)
                    # Say what arrived instead of naming only what did
                    # not. A bare "greeting did not appear" is true of a
                    # timeout, of a QEMU that already exited, and of a
                    # capability line read out of order -- three different
                    # repairs. Under `make allcheck` the QEMU subchecks run
                    # concurrently, so a slow start looks exactly like a
                    # broken one from here.
                    greeting_line = qmp_file.readline()
                    if not greeting_line:
                        raise SystemExit(
                            "QMP sent nothing before the deadline: the port "
                            "accepted a connection but QEMU produced no "
                            "greeting, so it is still starting or has already "
                            "exited")
                    try:
                        greeting = json.loads(greeting_line)
                    except json.JSONDecodeError as exc:
                        raise SystemExit(
                            "QMP greeting was not JSON (%s): %r"
                            % (exc, greeting_line[:200]))
                    if "QMP" not in greeting:
                        raise SystemExit(
                            "QMP greeting did not appear; the first line was "
                            "%r" % (greeting_line[:200],))
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
