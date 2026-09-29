#!/usr/bin/env python3
"""Open a gdb stub on a QEMU that is already running the shell image.

`make kernelsh-qemu` (and scripts/run_kernel_churn.py, which drives it)
starts QEMU with a QMP socket but no gdb stub, because an interactive session
should not pay for one. A hang found hours into a churn run is exactly when
one is wanted, and restarting to add it loses the hang. This asks the
running QEMU for a stub through QMP and prints the gdb command to attach.

    scripts/qemu_shell_gdbserver.py _build/kernel-churn-long-qemu [PORT]

Two traps, each paid for once while chasing GitHub issue #632:

- The QMP connection is closed as soon as the stub is open. The shell's own
  console sends DDB's serial BREAK through the same socket, and while this
  connection stays open that BREAK silently never arrives.
- Do not read the GIC's MMIO registers through the stub (x/wx 0x08000000...)
  or through the monitor's `xp`. Either one ended the QEMU process, taking
  the hang with it. Read kernel variables and registers instead: `x/8gx
  &kernel_world_stop`, `info threads`, `thread apply all bt`, and `p/x
  $cpsr` for each CPU's interrupt mask.
"""

import json
import pathlib
import socket
import sys


def qmp(sock_path: pathlib.Path, command: str) -> str:
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.connect(str(sock_path))
    with connection, connection.makefile("rwb", buffering=0) as stream:
        stream.readline()  # greeting
        stream.write(b'{"execute":"qmp_capabilities"}\n')
        stream.readline()
        request = {"execute": "human-monitor-command",
                   "arguments": {"command-line": command}}
        stream.write(json.dumps(request).encode("ascii") + b"\n")
        return json.loads(stream.readline()).get("return", "")


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__.splitlines()[0], file=sys.stderr)
        print("usage: qemu_shell_gdbserver.py ARTIFACT_DIR [PORT]",
              file=sys.stderr)
        return 2
    artifact = pathlib.Path(sys.argv[1])
    port = int(sys.argv[2]) if len(sys.argv) == 3 else 18698
    sock_path = artifact / "qmp.sock"
    if not sock_path.is_socket():
        print(f"error: no QMP socket at {sock_path}; is the shell QEMU "
              "still running?", file=sys.stderr)
        return 1
    answer = qmp(sock_path, f"gdbserver tcp::{port}").strip()
    print(f"qemu: {answer}")
    repo = pathlib.Path(__file__).resolve().parent.parent
    print("attach with:")
    print(f"  gdb-multiarch -q {repo}/kernel/build/qemu/kernel.elf "
          f"-ex 'target remote :{port}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
