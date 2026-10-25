#!/usr/bin/env python3
"""Run the stage-1 multicore load once on QEMU and record what it measured.

GitHub issue #742 stage 1: load the kernel the way real programs do, with
programs Linux distributions ship -- BusyBox `xargs -P`, stress-ng's fork,
pipe and exec stressors, hackbench -- and no threads. /bin/load.sh in the
load image (`kernel/build/user/ext2-load.img`) runs them; this runner boots
the interactive shell on that image under a pty, as run_kernel_churn.py
does, types `load.sh SECONDS JOBS LOOPS`, and reads one result per phase.

It is a FINDER, not a check, and it is in no aggregate. A clean run proves
nothing about a rare window and is never the evidence a defect is fixed;
anything it finds gets a deterministic lane before its issue closes.

One sample fails on the first of:
- the verdict line never arriving (a hang: DDB's views are then captured),
- a phase ending with a nonzero status (a program failed),
- a kernel oops, a starved-CPU report, or a DDB prompt nobody asked for.

Times are RECORDED, never judged: under QEMU they measure the host
(AGENTS.md, "QEMU's role"); the RPi5 decides time verdicts. The report --
per phase, the host-measured span between its begin and end lines, plus
stress-ng's bogo-ops rates and hackbench's `Time:` -- is printed and kept in
<artifact root>/kernel-load-qemu/load-report.txt beside the transcript.
"""

import argparse
import os
import pty
import re
import select
import signal
import sys
import time

import run_kernel_churn as churn
from lease_wait import timed_out_waiting
from qemu_vcpu_lease import lease, shell_vcpus


REPO_ROOT = churn.REPO_ROOT
LOAD_IMAGE = os.path.join(REPO_ROOT, "kernel/build/user/ext2-load.img")
# /bin/load.sh's phases, in the order it runs those asked for, and its last
# line. The prefixes are fixed
# strings so scripts/check_kernel_log_expectations.py can hold them to the
# script that prints them.
PHASES = ("xargs", "fork", "exec", "pipe", "hackbench")
# Phases that cannot run on this kernel yet, and the issue each waits for.
# They are left out of the default list and named in every report, so a
# clean sample never reads as covering them; ask for one with --phases to
# watch it fail. Remove an entry when its issue lands.
PHASE_WAITS = {
    "fork": "#1041 (stress-ng's 8 MiB image span)",
    "exec": "#1041 (stress-ng's 8 MiB image span)",
    "pipe": "#1041 and #1042 (pipe2)",
    "hackbench": "#1042 (pipe2)",
}
DEFAULT_PHASES = tuple(name for name in PHASES if name not in PHASE_WAITS)
BEGIN_PREFIX = b"load: begin "
END_PREFIX = b"load: end "
VERDICT_PREFIX = b"load: phases="
VERDICT = re.compile(rb"\n" + re.escape(VERDICT_PREFIX) +
                     rb"([0-9]+) failed=([0-9]+)\n")
END = re.compile(rb"\n" + re.escape(END_PREFIX) + rb"([a-z]+) status=([0-9]+)\n")
# DDB's `unimpl`: the syscall numbers some process reached that the kernel
# answered with ENOSYS (GitHub issue #640). The load's inventory of missing
# ABI is read from here, not guessed from a program's error text.
UNIMPL_COUNT = re.compile(rb"\nddb: unimpl count=([0-9]+)\n")
UNIMPL = re.compile(rb"\nddb: unimpl nr=([0-9]+) first-pid=([0-9]+)(?=\n)")
# stress-ng --metrics-brief: `stress-ng: metrc: [pid] NAME OPS REAL USR SYS
# OPS/S(REAL) OPS/S(USR+SYS)`.
METRIC = re.compile(rb"stress-ng: metrc: \[[0-9]+\] +([a-z-]+) +([0-9]+) +"
                    rb"([0-9.]+) +([0-9.]+) +([0-9.]+) +([0-9.]+) +([0-9.]+)")
HACKBENCH_TIME = re.compile(rb"\nTime: ([0-9.]+)\n")
BOOT_TIMEOUT_SECONDS = 90
EXIT_TIMEOUT_SECONDS = 15


def ddb_read_unimpl(session):
    """Break into DDB, read `unimpl`, continue. The numbers, or None."""
    start = len(session.normalized())
    session.send(b"\x14b")
    if session.wait_for(lambda n: n.count(b"ddb> ", start) > 0, 20,
                        await_name="DDB prompt for unimpl") is None:
        return None
    session.send(b"unimpl\n")
    found = session.wait_for(
        lambda n: UNIMPL_COUNT.search(n, start) and n.count(b"ddb> ", start) > 1,
        20, await_name="DDB unimpl reading")
    text = session.normalized()
    session.send(b"continue\n")
    session.wait_for(lambda n: churn.DDB_CONTINUED in n[start:], 20,
                     await_name="DDB continue after unimpl")
    if not found:
        return None
    return [(int(m.group(1)), int(m.group(2)))
            for m in UNIMPL.finditer(text, start)]


def run_load(session, seconds, jobs, loops, phases, stall_seconds):
    """Type one load.sh and follow it. (failure or None, per-phase record)."""
    if churn.shell_resync(session) is False:
        return "the shell did not answer an empty line before the load", {}
    start = len(session.normalized())
    command = (f"load.sh {seconds} {jobs} {loops} " +
               " ".join(phases)).encode("ascii")
    session.send(command + b"\n")
    record = {}
    begun = {}
    seen_begin = 0
    seen_end = 0
    while True:
        def progress(text):
            # One read can bring a phase's end and the verdict together, so
            # the phase lines are taken first, one at a time.
            if text.count(BEGIN_PREFIX, start) > seen_begin:
                return "begin"
            if text.count(END_PREFIX, start) > seen_end:
                return "end"
            if VERDICT.search(text, start):
                return "verdict"
            if churn.has_returned_prompt(text[start:], command):
                return "prompt"
            return None
        answer = session.wait_for(progress, stall_seconds, watch_from=start,
                                  await_name="load phase line or verdict")
        now = time.monotonic()
        text = session.normalized()
        if isinstance(answer, churn.FailureMarker):
            session.wait_for(lambda n: False, 15)
            return (f"the kernel printed {answer.marker.decode().strip()!r}",
                    record)
        if answer is None:
            churn.ddb_walk_hang(session)
            running = [name for name in begun if name not in record]
            return (f"no load line for {stall_seconds} s (phase "
                    f"{running[-1] if running else 'none'} running): the load "
                    "hung; DDB's views are in the transcript", record)
        if answer == "begin":
            seen_begin += 1
            begun[phases[min(seen_begin, len(phases)) - 1]] = now
            continue
        if answer == "end":
            seen_end += 1
            ends = list(END.finditer(text, start))
            if len(ends) < seen_end:
                # The line has not fully arrived; read it on the next pass.
                seen_end -= 1
                session.wait_for(lambda n: False, 0.25)
                continue
            name = ends[seen_end - 1].group(1).decode("ascii")
            status = int(ends[seen_end - 1].group(2))
            record[name] = {"status": status,
                            "host_seconds": now - begun.get(name, now)}
            continue
        if answer == "prompt":
            return ("the shell prompt returned without a verdict: "
                    + churn.last_lines(text[start:]), record)
        verdict = VERDICT.search(text, start)
        for metric in METRIC.finditer(text, start):
            name = metric.group(1).decode("ascii")
            if name in record:
                record[name]["bogo_ops"] = int(metric.group(2))
                record[name]["ops_per_real_second"] = float(metric.group(6))
                record[name]["ops_per_cpu_second"] = float(metric.group(7))
        hackbench = HACKBENCH_TIME.search(text, start)
        if hackbench and "hackbench" in record:
            record["hackbench"]["reported_seconds"] = float(hackbench.group(1))
        ran, failed = int(verdict.group(1)), int(verdict.group(2))
        if ran != len(phases) or failed != 0:
            bad = [name for name, entry in record.items() if entry["status"]]
            return (f"verdict phases={ran} failed={failed} "
                    f"(failing: {' '.join(bad) or 'unknown'})", record)
        return None, record


def report_lines(label, args, record, unimpl):
    lines = [f"{label} phases={','.join(args.phases)} "
             f"seconds={args.seconds} jobs={args.jobs} "
             f"loops={args.loops} smp={os.environ.get('KERNEL_QEMU_SHELL_SMP', '?')} "
             "(times RECORDED, not judged)"]
    for name in PHASES:
        if name not in args.phases:
            if name in PHASE_WAITS:
                lines.append(f"{label} {name}: not run, waits for "
                             f"{PHASE_WAITS[name]}")
            continue
        entry = record.get(name)
        if entry is None:
            lines.append(f"{label} {name}: not reached")
            continue
        parts = [f"status={entry['status']}",
                 f"host-seconds={entry['host_seconds']:.2f}"]
        if "bogo_ops" in entry:
            parts += [f"bogo-ops={entry['bogo_ops']}",
                      f"ops/s-real={entry['ops_per_real_second']:.2f}",
                      f"ops/s-cpu={entry['ops_per_cpu_second']:.2f}"]
        if "reported_seconds" in entry:
            parts.append(f"reported-seconds={entry['reported_seconds']:.3f}")
        lines.append(f"{label} {name}: " + " ".join(parts))
    if unimpl is None:
        lines.append(f"{label} unimplemented syscalls: DDB gave no reading")
    else:
        lines.append(f"{label} unimplemented syscalls reached: " + (
            " ".join(f"nr={number}(first-pid={pid})" for number, pid in unimpl)
            or "none"))
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--platform", choices=("qemu",), required=True)
    parser.add_argument("--seconds", type=int, default=10,
                        help="each stress-ng stressor's run")
    parser.add_argument("--jobs", type=int, default=64,
                        help="BusyBox xargs -P jobs")
    parser.add_argument("--loops", type=int, default=200,
                        help="hackbench loops")
    parser.add_argument("--phases", default=",".join(DEFAULT_PHASES),
                        help="comma-separated phases, from: " + ",".join(PHASES))
    parser.add_argument("--stall-seconds", type=int, default=0,
                        help="seconds without a load line that count as a "
                             "hang; 0 means 600, or three stressor runs plus "
                             "300 if longer (64 xargs jobs took 82 s on QEMU)")
    args = parser.parse_args()
    args.phases = [name for name in args.phases.split(",") if name]
    if not args.phases or any(name not in PHASES for name in args.phases):
        parser.error("phases must be a nonempty list from " + ",".join(PHASES))
    if min(args.seconds, args.jobs, args.loops) <= 0 or args.stall_seconds < 0:
        parser.error("seconds, jobs and loops must be positive")
    if not os.path.isfile(LOAD_IMAGE):
        parser.error(f"{os.path.relpath(LOAD_IMAGE, REPO_ROOT)} is missing; "
                     "run make load-qemu")
    stall_seconds = args.stall_seconds or max(600, 3 * args.seconds + 300)
    lease(shell_vcpus())
    churn.RESYNC_SECONDS = churn.RESYNC_SECONDS_BY_PLATFORM["qemu"]

    root = os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT",
                          os.path.join(REPO_ROOT, "_build"))
    artifact_dir = os.path.join(root, "kernel-load-qemu")
    os.makedirs(artifact_dir, exist_ok=True)
    transcript_path = os.path.join(artifact_dir, "load-transcript.log")
    report_path = os.path.join(artifact_dir, "load-report.txt")
    label = "[kernel/qemu load]"

    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(REPO_ROOT)
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        os.environ["KERNEL_QEMU_SHELL_ARTIFACT_DIR"] = artifact_dir
        os.environ["KERNEL_QEMU_SHELL_EXT2_IMAGE"] = LOAD_IMAGE
        os.environ["KERNEL_QEMU_SHELL_SKIP_NETWORK"] = "1"
        os.execvp("bash", ["bash", "scripts/run_kernel_shell_qemu.sh"])

    session = churn.Session(pid, terminal, await_log=transcript_path,
                            label="kernel/qemu load")

    def stop(signum, frame):
        raise SystemExit(f"stopped by signal {signum}")
    signal.signal(signal.SIGTERM, stop)
    failure = None
    record = {}
    unimpl = None
    ready = None
    try:
        ready = session.wait_for(
            lambda n: any(marker in n for marker in churn.READY_MARKERS),
            BOOT_TIMEOUT_SECONDS, await_name="shell readiness")
        if ready is None:
            failure = (timed_out_waiting(session.transcript) or
                       "the shell never became ready")
        if failure is None:
            failure, record = run_load(session, args.seconds, args.jobs,
                                       args.loops, args.phases, stall_seconds)
        # The inventory is read after a failed phase too: a missing syscall
        # is the likeliest reason a program failed. Not after a hang or an
        # oops, where DDB has already been entered or cannot answer.
        if ready is not None and (failure is None or failure.startswith(
                ("verdict", "the shell prompt"))):
            unimpl = ddb_read_unimpl(session)
        try:
            session.send(b"\x1d")
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
                session.transcript.extend(data)
            exited, _ = os.waitpid(pid, os.WNOHANG)
            if exited:
                pid = 0
                break
    finally:
        if pid:
            churn.terminate(pid)
        os.close(terminal)
        with open(transcript_path, "wb") as handle:
            handle.write(bytes(session.transcript))

    lines = report_lines(label, args, record, unimpl)
    with open(report_path, "w", encoding="ascii") as handle:
        handle.write("\n".join(lines) + "\n")
    for line in lines:
        print(line)
    shown = os.path.relpath(transcript_path, REPO_ROOT)
    if failure is not None:
        print(f"FAIL {label}: {failure}; transcript in {shown}",
              file=sys.stderr)
        return 1
    print(f"PASS {label}: {len(args.phases)} phases, every program exited 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
