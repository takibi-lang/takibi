#!/usr/bin/env python3
"""Capture a bounded, read-only console snapshot before serial BREAK changes it."""

import argparse
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def qmp(port, command, arguments=None):
    if isinstance(port, int):
        connection = socket.create_connection(("127.0.0.1", port), timeout=2)
    else:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(2)
        try:
            connection.connect(str(port))
        except OSError:
            connection.close()
            raise
    with connection:
        deadline = time.monotonic() + 2
        with connection.makefile("rwb", buffering=0) as stream:
            greeting = json.loads(stream.readline())
            if "QMP" not in greeting:
                raise RuntimeError("missing QMP greeting")
            for request in ({"execute": "qmp_capabilities", "id": 1},
                            {"execute": command, "arguments": arguments or {}, "id": 2}):
                stream.write(json.dumps(request).encode("ascii") + b"\n")
                while True:
                    connection.settimeout(max(0.001, deadline - time.monotonic()))
                    if time.monotonic() >= deadline:
                        raise RuntimeError("QMP reply budget exhausted")
                    response = json.loads(stream.readline(65536))
                    if response.get("id") == request["id"]:
                        break
                if "error" in response:
                    raise RuntimeError(str(response["error"]))
            return response["return"]


def capture(port, elf, output, phase, gdb_endpoint=None):
    """Never replace the lane's original failure with a diagnostic failure.

    The QMP connection is closed before GDB or the caller's serial BREAK.
    GDB attachment stops every CPU; disconnect and the finally block restore the
    prior running/paused state even after a failed or timed-out read.
    """
    repo = Path(__file__).resolve().parent.parent
    log = Path(output)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="ascii") as stream:
        stream.write(f"console snapshot phase: {phase}\nELF: {Path(elf).resolve()}\n")
        stream.flush()
        was_running = None
        owned_stub = False
        try:
            for sidecar in ("kernel-debug-metadata.json", "kernel-console-layout.gdb"):
                if not (repo / "_build" / sidecar).is_file():
                    raise RuntimeError("missing compiler sidecar: " + sidecar)
            was_running = qmp(port, "query-status")["running"]
            with tempfile.TemporaryDirectory(prefix="tk-console-") as directory:
                endpoint = gdb_endpoint or str(Path(directory) / "gdb")
                if gdb_endpoint is None:
                    reply = qmp(port, "human-monitor-command", {
                        "command-line": f"gdbserver unix:{endpoint},server=on,wait=off"})
                    if not Path(endpoint).is_socket():
                        raise RuntimeError("cannot open GDB stub: " + reply.strip())
                    owned_stub = True
                commands = [
                    "set pagination off", "set remotetimeout 2",
                    f"target remote {endpoint}",
                    f"source {repo}/scripts/kernel_debug_metadata.gdb",
                    f"takibi-debug-metadata {repo}/_build/kernel-debug-metadata.json",
                    f"source {repo}/_build/kernel-console-layout.gdb",
                    f"source {repo}/scripts/kernel_console.gdb",
                    "takibi-console", "disconnect",
                ]
                argv = ["gdb-multiarch", "-nx", "-q", "-batch", str(elf)]
                for command in commands:
                    argv.extend(["-ex", command])
                result = subprocess.run(argv, stdout=stream, stderr=stream, timeout=8)
                stream.flush()
                if result.returncode:
                    raise RuntimeError(f"GDB exited {result.returncode}")
                if "console snapshot complete\n" not in log.read_text(encoding="ascii"):
                    raise RuntimeError("GDB did not complete the console reader")
                stream.write("console snapshot status: captured\n")
        except Exception as error:  # A diagnostic must preserve the original lane verdict.
            stream.write(f"console snapshot status: unavailable: {error}\n")
        finally:
            if owned_stub:
                try:
                    qmp(port, "human-monitor-command", {"command-line": "gdbserver none"})
                except Exception as error:
                    stream.write(f"console snapshot stub cleanup: unavailable: {error}\n")
            if was_running is not None:
                try:
                    qmp(port, "cont" if was_running else "stop")
                except Exception as error:  # Restoration failure is also evidence.
                    stream.write(f"console snapshot restore: unavailable: {error}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    endpoint = parser.add_mutually_exclusive_group(required=True)
    endpoint.add_argument("--qmp-port", type=int)
    endpoint.add_argument("--qmp-socket")
    parser.add_argument("--elf", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--phase", default="manual")
    args = parser.parse_args()
    capture(args.qmp_port if args.qmp_port is not None else args.qmp_socket,
            args.elf, args.output, args.phase)


if __name__ == "__main__":
    main()
