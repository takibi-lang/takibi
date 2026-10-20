#!/usr/bin/env python3
"""Controls for the QMP reply-read check and for every QMP client (#880).

Lint controls: a raw read after a command is refused, the greeting read and
qmp_reply are accepted. Wire controls: each client talks to a fake QMP server
that sends an async RESUME event before every reply (and, for the id-matching
client, a reply with another id first); a client that takes the first line as
its reply fails here.
"""

import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_qmp_reply_reads.py"
CASES = CaseCount()

RAW_AFTER = ("def qmp(stream):\n"
             "    stream.readline()\n"
             "    stream.write(b'{\"execute\":\"qmp_capabilities\"}\\n')\n"
             "    return stream.readline()\n")
RAW_RECV = ("def qmp(sock):\n"
            "    sock.recv(4096)\n"
            "    sock.sendall(b'{\"execute\":\"qmp_capabilities\"}\\n')\n"
            "    return sock.recv(4096)\n")
NESTED = ("def outer(stream):\n"
          "    def inner():\n"
          "        stream.write(b'qmp_capabilities')\n"
          "        return stream.readline()\n"
          "    return inner()\n")
HELPER_USED = ("from qmp_wire import qmp_reply\n\n"
               "def qmp(stream):\n"
               "    stream.readline()\n"
               "    stream.write(b'{\"execute\":\"qmp_capabilities\"}\\n')\n"
               "    return qmp_reply(stream)\n")
SERIAL_FIRST = ("def main(serial, stream):\n"
                "    serial.recv(10)\n"
                "    stream.readline()\n"
                "    stream.write(b'qmp_capabilities')\n")


def lint(body):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        (root / "scripts").mkdir()
        for copied in (CHECK, "pass_line.py"):
            shutil.copy(REPO / "scripts" / copied, root / "scripts" / copied)
        (root / "scripts" / "client.py").write_text(body)
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
        return done.returncode


REGISTERS = "CPU#0\n PC=0000000040080000 PSTATE=600003c5\n"


class FakeQmp:
    """Greets, then answers every request after an async RESUME event."""

    def __init__(self, unix_path=None):
        if unix_path:
            self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.server.bind(unix_path)
            self.address = unix_path
        else:
            self.server = socket.create_server(("127.0.0.1", 0))
            self.address = self.server.getsockname()[1]
        self.server.listen(4)
        self.server.settimeout(10)
        self.requests = []
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.close()
        self.thread.join(5)

    def serve(self):
        try:
            while True:
                connection, _ = self.server.accept()
                with connection, connection.makefile("rwb", buffering=0) as s:
                    s.write(b'{"QMP": {"version": {}, "capabilities": []}}\n')
                    for line in s:
                        request = json.loads(line)
                        self.requests.append(request.get("execute"))
                        s.write(b'{"event": "RESUME", "data": {}, '
                                b'"timestamp": {"seconds": 1, '
                                b'"microseconds": 0}}\n')
                        command = request.get("arguments", {}).get(
                            "command-line", "")
                        value = REGISTERS if command.startswith(
                            "info registers") else (
                            "gdbserver ok" if command else {})
                        reply = {"return": value}
                        if "id" in request:
                            s.write(json.dumps(
                                {"return": "stale", "id": -1}).encode() + b"\n")
                            reply["id"] = request["id"]
                        s.write(json.dumps(reply).encode() + b"\n")
        except OSError:
            return


def wire_controls(failures):
    sys.path.insert(0, str(REPO / "scripts"))
    import run_kernel_ddb_driver
    import qemu_shell_gdbserver
    import run_kernel_shell_console
    import capture_kernel_console

    CASES.note()
    with FakeQmp() as qmp:
        _dump, summary = run_kernel_ddb_driver.sample_cpu_registers(
            qmp.address, 5.0)
    if "cpu0 pc=0000000040080000" not in summary:
        failures.append(f"ddb sample_cpu_registers took an event: {summary!r}")

    with tempfile.TemporaryDirectory() as raw:
        CASES.note()
        path = os.path.join(raw, "q.sock")
        with FakeQmp(path):
            answer = qemu_shell_gdbserver.qmp(pathlib.Path(path),
                                              "gdbserver tcp::1")
        if answer != "gdbserver ok":
            failures.append(f"qemu_shell_gdbserver.qmp took {answer!r}")

        CASES.note()
        path = os.path.join(raw, "s.sock")
        with FakeQmp(path) as qmp:
            try:
                run_kernel_shell_console.qmp_execute(
                    path, "chardev-send-break", {"id": "debug_uart"})
            except RuntimeError as error:
                failures.append(f"shell console qmp_execute refused: {error}")
        if qmp.requests != ["qmp_capabilities", "chardev-send-break"]:
            failures.append(f"shell console sent {qmp.requests!r}")

    CASES.note()
    with FakeQmp() as qmp:
        try:
            status = capture_kernel_console.qmp(qmp.address, "query-status")
        except (RuntimeError, ValueError) as error:
            status = error
    if status != {}:
        failures.append(f"capture_kernel_console.qmp returned {status!r}")


def main():
    failures = []
    if lint(RAW_AFTER) == 0:
        failures.append("a raw readline after qmp_capabilities passed")
    if lint(RAW_RECV) == 0:
        failures.append("a raw recv after qmp_capabilities passed")
    if lint(NESTED) == 0:
        failures.append("a raw read in a nested function passed")
    if lint(HELPER_USED) != 0:
        failures.append("a client reading through qmp_reply was refused")
    if lint(SERIAL_FIRST) != 0:
        failures.append("reads before the capability negotiation were refused")
    wire_controls(failures)
    if failures:
        for failure in failures:
            print(f"ERROR\tqmp-reply-read controls: {failure}")
        print(f"FAIL qmp-reply-read controls: {len(failures)} failure(s)")
        return 1
    report_pass("qmp-reply-read controls",
                "raw reads after a command refused; every client skips an "
                "async event before its reply", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
