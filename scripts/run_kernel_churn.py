#!/usr/bin/env python3
"""Run the process-churn workload once on QEMU or the RPi5 and give a verdict.

GitHub issue #584: multicore defects have been found by running something,
not by reading something, and the thing to run is process lifecycle --
fork, exec, exit, signal, wait and slot reuse -- across cores. The workload
is /bin/churn.sh in the rootfs. This runner boots the interactive-shell image
(`make kernelsh-qemu` or `make kernelsh-rpi5`) under a pty, exactly as a
person at the terminal would, types `churn.sh ROUNDS` once the shell is
reading, and reads its verdict line.

It is a FINDER, not a check. It is in no aggregate: a clean run proves
nothing about a rare window, and a board run on every commit would make the
board the queue everyone waits in (AGENTS.md). Run it as a rate with
scripts/repeat_kernel_lane.sh; anything it finds gets a deterministic lane
before its issue closes.

One sample fails on the first of:
- the verdict line never arriving before the deadline (a hang: the
  capture then shows where the shell stopped),
- a verdict with mismatched statuses (a child returned the wrong status),
- a kernel oops, a starved-CPU report, or a DDB prompt nobody asked for.

The pty transcript lands in <artifact root>/kernel-churn-<platform>/, beside
the shell runner's own UART transcript.
"""

import argparse
import os
import pty
import re
import select
import signal
import sys
import time


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
READY_MARKERS = (
    b"persistent shell: uart blocked",
    b"interactive shell: uart blocked",
)
# /bin/churn.sh's last line. The prefix is what is waited for, as a fixed
# string, so scripts/check_kernel_log_expectations.py can hold it to the
# script that prints it; the numbers are read from the rest of the line.
VERDICT_PREFIX = b"churn: rounds="
VERDICT = re.compile(rb"\n" + re.escape(VERDICT_PREFIX) +
                     rb"([0-9]+) mismatched=([0-9]+)\n")
# Kernel text that means something went wrong whatever the shell says.
# `oops: ` is every crash report's prefix, `sched: STARVED` the idle-beside-
# Ready report, and `ddb> ` a debugger prompt this runner never asks for.
# The shell runners print their own `[kernel/<platform>] ...` notices into
# the same terminal, and one can land inside a kernel line: on the RPi5's
# 115200-baud UART the readiness notice split `interactive shell: uart
# blocked` in two in five samples of five. Remove them before matching.
HOST_NOTICE = re.compile(rb"\[kernel/[a-z0-9]+\][^\n]*\n")
FAILURE_MARKERS = (b"oops: ", b"sched: STARVED", b"ddb> ")
BOOT_TIMEOUT_SECONDS = {"qemu": 90, "rpi5": 120}
# Measured on QEMU: 100 rounds of a similar loop took 40 s. The deadline is
# per round so a longer run is not a different verdict.
SECONDS_PER_ROUND = 2.0
EXIT_TIMEOUT_SECONDS = 15


def terminate(pid):
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            exited, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if exited:
            return
        time.sleep(0.05)
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--platform", choices=("qemu", "rpi5"), required=True)
    parser.add_argument("--rounds", type=int, default=100)
    args = parser.parse_args()

    root = os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT",
                          os.path.join(REPO_ROOT, "_build"))
    artifact_dir = os.path.join(root, f"kernel-churn-{args.platform}")
    os.makedirs(artifact_dir, exist_ok=True)
    transcript_path = os.path.join(artifact_dir, "churn-transcript.log")
    label = f"[kernel/{args.platform} churn]"

    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(REPO_ROOT)
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        if args.platform == "qemu":
            os.environ["KERNEL_QEMU_SHELL_ARTIFACT_DIR"] = artifact_dir
            # The workload needs no network; skipping the bridge also
            # keeps a sample from depending on a free host port for it.
            os.environ["KERNEL_QEMU_SHELL_SKIP_NETWORK"] = "1"
            os.execvp("make", ["make", "-j1", "kernelsh-qemu"])
        os.environ["KERNEL_RPI5_SHELL_ARTIFACT_DIR"] = artifact_dir
        # The host-side ARP/ICMP/TCP peer needs sudo and tests the network,
        # which this workload does not use.
        os.environ["KERNEL_RPI5_SHELL_NETWORK_PEER"] = "0"
        os.execvp("make", ["make", "-j1", "kernelsh-rpi5"])

    transcript = bytearray()
    command = f"churn.sh {args.rounds}\n".encode("ascii")
    sent_at = None
    deadline = time.monotonic() + BOOT_TIMEOUT_SECONDS[args.platform]
    verdict = None
    failure = None
    try:
        while failure is None and verdict is None:
            if time.monotonic() >= deadline:
                failure = ("the shell never became ready" if sent_at is None
                           else f"no verdict within {args.rounds} rounds' "
                                "deadline: the workload hung")
                break
            readable, _, _ = select.select([terminal], [], [], 0.25)
            if readable:
                try:
                    data = os.read(terminal, 4096)
                except OSError:
                    data = b""
                if not data:
                    failure = "the shell runner exited before a verdict"
                    break
                transcript.extend(data)
            normalized = HOST_NOTICE.sub(
                b"", bytes(transcript).replace(b"\r", b""))
            if sent_at is None:
                if any(marker in normalized for marker in READY_MARKERS):
                    # Everything before this point is boot; judge only
                    # what follows the command.
                    os.write(terminal, command)
                    sent_at = len(normalized)
                    deadline = (time.monotonic() +
                                args.rounds * SECONDS_PER_ROUND + 10)
                continue
            after = normalized[sent_at:]
            for marker in FAILURE_MARKERS:
                if marker in after:
                    failure = f"the kernel printed {marker.decode().strip()!r}"
            match = VERDICT.search(after)
            if match is not None:
                verdict = (int(match.group(1)), int(match.group(2)))
        if failure is None:
            rounds, mismatched = verdict
            if rounds != args.rounds or mismatched != 0:
                failure = (f"verdict rounds={rounds} mismatched={mismatched}, "
                           f"expected rounds={args.rounds} mismatched=0")
        # Leave miniterm the ordinary way so the runner tears QEMU or the
        # board session down itself.
        try:
            os.write(terminal, b"\x1d")
        except OSError:
            pass
        deadline = time.monotonic() + EXIT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.25)
            if readable:
                try:
                    data = os.read(terminal, 4096)
                except OSError:
                    data = b""
                transcript.extend(data)
            exited, _ = os.waitpid(pid, os.WNOHANG)
            if exited:
                pid = 0
                break
    finally:
        if pid:
            terminate(pid)
        os.close(terminal)
        with open(transcript_path, "wb") as handle:
            handle.write(bytes(transcript))

    shown = os.path.relpath(transcript_path, REPO_ROOT)
    if failure is not None:
        print(f"FAIL {label}: {failure}; transcript in {shown}",
              file=sys.stderr)
        return 1
    print(f"PASS {label}: {args.rounds} rounds, every status as expected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
