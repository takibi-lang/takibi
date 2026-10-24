#!/usr/bin/env python3
"""Boot the ordinary QEMU suite with the lifecycle trace on (GitHub issue #965).

The lifecycle trace is debugger-owned: nothing in the kernel switches it on
for the whole boot, so no ordinary lane ran the suite with it recording. #652
found kernel_process_trace_disable ending a debugger-enabled trace at the
first probe; nothing kept "the suite passes with the trace on" true after the
fix. scripts/run_kernel_qemutest.sh calls this when KERNEL_QEMU_TRACE_FROM_BOOT
is set (kernelcheck-qemu-debug-main sets it), in two steps on the guest's own
GDB stub:

  arm     QEMU was started halted (-S). Stop at main, after .bss is cleared
          and before any process, probe or fixture runs, and set both the
          boot switch and the live switch -- what DDB `trace on` sets -- then
          detach. `--fail-after-exec` also sets the default-false fail-stop
          switch: the negative control, a trace-on boot that cannot pass.

  verify  After the suite's stop marker, read both switches back and the
          shared sequence counter. A boot whose arm silently missed would
          pass the suite with the trace off and prove nothing, so this
          refuses a switch that is off or a ring that recorded nothing since
          the last execution reset.

Exit 0 on success, 1 with a reason on stderr otherwise.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import time

GDB_TIMEOUT_SECONDS = 120


def gdb(elf: str, socket: str, commands: list[str], log: pathlib.Path,
        timeout: float) -> str:
    argv = ["gdb-multiarch", "-nx", "-q", "-batch", elf,
            "-ex", "set pagination off", "-ex", "set confirm off",
            "-ex", f"target remote {socket}"]
    for command in commands:
        argv.extend(["-ex", command])
    result = subprocess.run(argv, capture_output=True, text=True,
                            timeout=timeout, check=False)
    output = result.stdout + result.stderr
    with log.open("a", encoding="ascii", errors="replace") as stream:
        stream.write(f"$ {' '.join(argv)}\n{output}\nexit {result.returncode}\n")
    if result.returncode != 0:
        raise RuntimeError(f"gdb exited {result.returncode}; see {log}")
    return output


def wait_socket(socket: str, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while not os.path.exists(socket):
        if time.monotonic() > deadline:
            raise RuntimeError(f"no GDB stub at {socket} after {timeout:.0f} s")
        time.sleep(0.1)


def arm(args: argparse.Namespace) -> None:
    wait_socket(args.socket, 30)
    commands = [
        "break main", "continue", "delete",
        "set var *(char *)&kernel_process_trace_boot_enabled = 1",
        "set var *(char *)&kernel_process_trace_enabled = 1",
    ]
    if args.fail_after_exec:
        commands.append(
            "set var *(char *)&kernel_process_trace_fail_after_exec = 1")
    commands += [
        "printf \"trace-from-boot armed boot=%d live=%d\\n\", "
        "*(char *)&kernel_process_trace_boot_enabled, "
        "*(char *)&kernel_process_trace_enabled",
        "detach",
    ]
    output = gdb(args.elf, args.socket, commands, pathlib.Path(args.log),
                 GDB_TIMEOUT_SECONDS)
    if "trace-from-boot armed boot=1 live=1" not in output:
        raise RuntimeError("the switches did not read back as set after arming")


VERIFY_LINE = re.compile(
    r"trace-from-boot state boot=(\d+) live=(\d+) sequence=(\d+)")


def judge(output: str) -> str:
    """The verdict on verify's GDB output; empty when the trace was on."""
    match = VERIFY_LINE.search(output)
    if not match:
        return "GDB printed no trace state"
    boot, live, sequence = (int(group) for group in match.groups())
    if boot != 1 or live != 1:
        return f"the trace is off at the end of the suite (boot={boot} live={live})"
    if sequence == 0:
        return "the trace recorded nothing since the last execution reset"
    return ""


def verify(args: argparse.Namespace) -> None:
    # The stop lands wherever a CPU is, often at EL0 under a user root whose
    # TTBR0 does not map the kernel's identity addresses; read physical
    # memory (kernel VA == PA on QEMU) through the stub instead.
    output = gdb(args.elf, args.socket, [
        "maintenance packet Qqemu.PhyMemMode:1",
        "printf \"trace-from-boot state boot=%d live=%d sequence=%lu\\n\", "
        "*(char *)&kernel_process_trace_boot_enabled, "
        "*(char *)&kernel_process_trace_enabled, "
        "*(unsigned long *)&kernel_crash_trace_sequence",
        "detach",
    ], pathlib.Path(args.log), 30)
    reason = judge(output)
    if reason:
        raise RuntimeError(reason)
    print(VERIFY_LINE.search(output).group(0))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", choices=("arm", "verify"))
    parser.add_argument("--elf", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--fail-after-exec", action="store_true")
    args = parser.parse_args()
    try:
        (arm if args.step == "arm" else verify)(args)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL trace-from-boot {args.step}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
