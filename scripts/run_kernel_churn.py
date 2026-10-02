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


class Session:
    """The pty around the shell runner, and what has arrived through it."""

    def __init__(self, pid, terminal):
        self.pid = pid
        self.terminal = terminal
        self.transcript = bytearray()

    def normalized(self):
        return HOST_NOTICE.sub(
            b"", bytes(self.transcript).replace(b"\r", b"").replace(
                CURSOR_QUERY, b""))



    def send(self, data):
        os.write(self.terminal, data)

    def wait_for(self, done, seconds, watch_from=None):
        """Read until done(normalized) returns something, and return it.

        None on a deadline or an exited runner. With watch_from, kernel
        failure text after that offset ends the wait with a FailureMarker.
        """
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.terminal], [], [], 0.25)
            if readable:
                try:
                    data = os.read(self.terminal, 4096)
                except OSError:
                    data = b""
                if not data:
                    return None
                self.transcript.extend(data)
            normalized = self.normalized()
            if watch_from is not None:
                for marker in FAILURE_MARKERS:
                    if marker in normalized[watch_from:]:
                        return FailureMarker(marker)
            answer = done(normalized)
            if answer:
                return answer
        return None


class PromptWithoutVerdict:
    pass


# BusyBox's line editor asks where the cursor is (ESC[6n) once termios
# works. Left unanswered it carries on with the prompt; an answer typed
# through this pty arrives as input text instead (`[1;1R`), so the query
# is only removed before matching.
CURSOR_QUERY = b"\x1b[6n"
# ash's interactive prompt. It follows the verdict line; see run_phase. With
# termios working, BusyBox's line editor prints ` # ` rather than `/ # `
# unless PS1 is set, so either counts.
SHELL_PROMPTS = (b"\n/ # ", b"\n # ")


def has_prompt(text):
    return any(prompt in text for prompt in SHELL_PROMPTS)


def has_returned_prompt(text, command):
    """A prompt that is not ash redrawing the line just typed.

    After a DDB `continue`, ash redraws its prompt with the pending command
    line after it (` # churn.sh 9000`). That is the phase starting, not
    ending, and counting it once ended a clean long run at the start of its
    second phase with "the shell prompt returned without a verdict"."""
    for prompt in SHELL_PROMPTS:
        at = text.find(prompt)
        while at >= 0:
            if not text.startswith(command, at + len(prompt)):
                return True
            at = text.find(prompt, at + 1)
    return False


def last_lines(text, count=4):
    lines = [line for line in text.decode("ascii", "replace").splitlines()
             if line.strip()]
    return " | ".join(lines[-count:])


class FailureMarker:
    def __init__(self, marker):
        self.marker = marker


# DDB's `vm` prints this line after the current process's; see
# ddb_render_vm. The long run reads it for what accumulates over a boot.
VM_GLOBAL = re.compile(
    rb"\nddb: vm-global asid-width=([0-9]+) asid-generation=([0-9]+) "
    rb"asid-next=([0-9]+) asid-rollovers=([0-9]+) "
    rb"pages-live=([0-9]+) pages-total=([0-9]+)\n")
DDB_CONTINUED = b"ddb: continuing"


def ddb_read_vm(session):
    """Break into DDB, read the global `vm` line, and continue.

    A dict of its fields, or None if the debugger did not answer.
    """
    start = len(session.normalized())
    # Ctrl-T then b: the shell console's serial BREAK, on both platforms.
    session.send(b"\x14b")
    if session.wait_for(lambda n: n.count(b"ddb> ", start) > 0, 20) is None:
        return None
    session.send(b"vm\n")
    found = session.wait_for(
        lambda n: VM_GLOBAL.search(n, start), 20)
    session.send(b"continue\n")
    if session.wait_for(lambda n: DDB_CONTINUED in n[start:], 20) is None:
        return None
    if found is None:
        return None
    names = ("asid_width", "asid_generation", "asid_next", "asid_rollovers",
             "pages_live", "pages_total")
    return dict(zip(names, (int(value) for value in found.groups())))


def shell_resync(session):
    """Wait until ash is reading a fresh line. False if it never does.

    Typed straight after a DDB `continue`, the command's first byte could
    reach ash as a line of its own: on the RPi5 `c` arrived, ash answered
    with a new prompt, and `hurn.sh 9000` followed -- so a phase ended
    before it began. An empty line and the prompt it draws put the shell
    and this runner back in step.
    """
    start = len(session.normalized())
    # GitHub issue #655: the evidence that tells a lost newline from a prompt
    # that arrived before `start` was taken. `prompt_before` is whether the
    # text up to `start` already ends in a prompt, which a resync that waits
    # only for what comes AFTER `start` would never count.
    prompt_before = has_prompt(session.normalized()[max(0, start - 16):start])
    sent_at = time.monotonic()
    session.send(b"\n")
    answer = session.wait_for(lambda n: has_prompt(n[start:]),
                              RESYNC_SECONDS)
    print(f"[churn resync] start={start} prompt_before_start={prompt_before} "
          f"answered={answer is not None} "
          f"after={time.monotonic() - sent_at:.1f}s "
          f"total={len(session.normalized())}", flush=True)
    if answer is None:
        # GitHub issue #655: whether the empty line was lost on the way in,
        # or its answer is stuck on the way out (a shell on a peer CPU whose
        # writes wait in that CPU's console ring until core 0 drains it,
        # #657/#663). DDB's ps/current say where ash is and whether it is
        # back in its terminal read; a prompt appearing once DDB is entered
        # is the answer having been held.
        held_from = len(session.normalized())
        ddb_walk_hang(session)
        late = has_prompt(session.normalized()[held_from:])
        print(f"[churn resync] no answer; a prompt arrived once DDB was "
              f"entered: {late}", flush=True)
        return False
    # Let anything still in flight from the debugger land before typing.
    settle = len(session.normalized())
    session.wait_for(lambda n: len(n) > settle, 1)
    return True


# /bin/churn.sh prints this every 500 rounds. A phase with no heartbeat for
# STALL_SECONDS has hung, whatever its overall deadline says. 500 rounds take
# about 70 s on the RPi5 and about 5.5 minutes under two-core QEMU.
PROGRESS = b"churn: progress "
STALL_SECONDS_BY_PLATFORM = {"rpi5": 300, "qemu": 900}
STALL_SECONDS = 300
# How long ash may take to answer the resync's empty line. Twenty seconds
# covers the board. QEMU inside an allcheck, beside every other lane, did not
# answer in 20 s once after a 7.8 s shell start, and failed the race-window
# 633 lane before its phase began.
RESYNC_SECONDS_BY_PLATFORM = {"rpi5": 20, "qemu": 60}
RESYNC_SECONDS = 20
# What DDB is asked when a phase hangs, so the capture says why.
HANG_COMMANDS = (b"ps", b"sched", b"wait", b"current", b"stacks", b"events",
                 b"intr", b"trace")


def ddb_walk_hang(session):
    """Break into DDB on a hung phase, record its read-only views, stay stopped.

    DDB refuses to inspect while another core holds the world stop (`busy`)
    or when a core does not stop (`partial`). Whether that refusal persists
    is itself the evidence -- a stop held for good, or cores trading it -- so
    the break is sent again a few times before giving up.
    """
    for _ in range(4):
        start = len(session.normalized())
        session.send(b"\x14b")
        session.wait_for(
            lambda n: b"ddb> " in n[start:] or
                      b"inspection refused" in n[start:], 20)
        if b"ddb> " in session.normalized()[start:]:
            break
        session.wait_for(lambda n: False, 10)
    else:
        return
    for command in HANG_COMMANDS:
        seen = session.normalized().count(b"ddb> ")
        session.send(command + b"\n")
        session.wait_for(lambda n: n.count(b"ddb> ") > seen, 20)


def run_phase(session, rounds):
    """Type one `churn.sh ROUNDS` and judge it. None, or why it failed."""
    if shell_resync(session) is False:
        return "the shell did not answer an empty line before the phase"
    start = len(session.normalized())
    command = f"churn.sh {rounds}".encode("ascii")
    session.send(command + b"\n")
    deadline = time.monotonic() + rounds * SECONDS_PER_ROUND + 10
    answer = None
    heartbeats = 0
    while answer is None and time.monotonic() < deadline:
        answer = session.wait_for(
            lambda n: VERDICT.search(n, start) or
                      (has_returned_prompt(n[start:], command) and
                       PromptWithoutVerdict()) or
                      (n.count(PROGRESS, start) > heartbeats and "beat"),
            min(STALL_SECONDS, max(1.0, deadline - time.monotonic())),
            watch_from=start)
        if answer == "beat":
            heartbeats = session.normalized().count(PROGRESS, start)
            answer = None
            continue
        if answer is None:
            ddb_walk_hang(session)
            return (f"no heartbeat for {STALL_SECONDS} s after "
                    f"{heartbeats * 500} rounds: the phase hung; DDB's views "
                    "are in the transcript")
    if isinstance(answer, PromptWithoutVerdict):
        # The verdict is printed before the next prompt, so a prompt with no
        # verdict ahead of it is the script ending early -- as it did when
        # ash printed `sh: out of memory` and returned at once, and the
        # runner then waited five hours for a line that could not come.
        return ("the shell prompt returned without a verdict: "
                + last_lines(session.normalized()[start:]))
    if answer is None:
        return f"no verdict within {rounds} rounds' deadline: the workload hung"
    if isinstance(answer, FailureMarker):
        # Keep reading: the first line of an oops is not the report, and
        # the crash console walks its read-only commands after it.
        session.wait_for(lambda n: False, 15)
        return f"the kernel printed {answer.marker.decode().strip()!r}"
    done, mismatched = int(answer.group(1)), int(answer.group(2))
    if done != rounds or mismatched != 0:
        return (f"verdict rounds={done} mismatched={mismatched}, "
                f"expected rounds={rounds} mismatched=0")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--platform", choices=("qemu", "rpi5"), required=True)
    parser.add_argument("--rounds", type=int, default=100)
    parser.add_argument(
        "--stall-seconds", type=int, default=0,
        help="seconds without a heartbeat or verdict that count as a hang; "
             "0 keeps the platform's default. A short run that must detect "
             "a hang quickly passes a smaller bound than a long run needs")
    parser.add_argument(
        "--long", action="store_true",
        help="the single long boot: two phases of ROUNDS each, DDB readings "
             "before and after, and a verdict on what accumulates")
    args = parser.parse_args()
    global STALL_SECONDS
    STALL_SECONDS = (args.stall_seconds or
                     STALL_SECONDS_BY_PLATFORM[args.platform])
    global RESYNC_SECONDS
    RESYNC_SECONDS = RESYNC_SECONDS_BY_PLATFORM[args.platform]

    root = os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT",
                          os.path.join(REPO_ROOT, "_build"))
    kind = "churn-long" if args.long else "churn"
    artifact_dir = os.path.join(root, f"kernel-{kind}-{args.platform}")
    os.makedirs(artifact_dir, exist_ok=True)
    transcript_path = os.path.join(artifact_dir, "churn-transcript.log")
    label = f"[kernel/{args.platform} {kind}]"

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

    session = Session(pid, terminal)

    # A runner stopped from outside (a timeout, a person) still leaves its
    # transcript: SIGTERM becomes an exception, so the `finally` below runs.
    def stop(signum, frame):
        raise SystemExit(f"stopped by signal {signum}")
    signal.signal(signal.SIGTERM, stop)
    failure = None
    readings = []
    try:
        ready = session.wait_for(
            lambda n: any(marker in n for marker in READY_MARKERS),
            BOOT_TIMEOUT_SECONDS[args.platform])
        if ready is None:
            failure = "the shell never became ready"
        phases = 2 if args.long else 1
        for phase in range(phases + 1):
            if failure is not None:
                break
            if args.long:
                reading = ddb_read_vm(session)
                if reading is None:
                    failure = f"DDB gave no vm reading before phase {phase + 1}"
                    break
                readings.append(reading)
                print(f"{label} reading {phase}: " + " ".join(
                    f"{key}={value}" for key, value in reading.items()))
            if phase == phases:
                break
            failure = run_phase(session, args.rounds)
        if failure is None and args.long:
            failure = judge_long(readings)
        # Leave miniterm the ordinary way so the runner tears QEMU or the
        # board session down itself.
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
            terminate(pid)
        os.close(terminal)
        with open(transcript_path, "wb") as handle:
            handle.write(bytes(session.transcript))

    shown = os.path.relpath(transcript_path, REPO_ROOT)
    if failure is not None:
        print(f"FAIL {label}: {failure}; transcript in {shown}",
              file=sys.stderr)
        return 1
    phases = "two phases of " if args.long else ""
    print(f"PASS {label}: {phases}{args.rounds} rounds, every status as expected")
    return 0


def judge_long(readings):
    """What the long boot is for, from the three DDB readings.

    - The ASID counter must have rolled over at least once: that is the
      accumulating event this run exists to reach, and a run that never
      got there has tested nothing it could not test in a short sample.
    - Pages in use after the second phase must not exceed pages in use
      after the first. The first phase is allowed to grow (caches warm,
      the shell's own heap settles); the second repeats identical work, so
      growth there is memory the workload keeps and never gives back.
    """
    before, first, second = readings
    if second["asid_rollovers"] <= before["asid_rollovers"]:
        return ("the ASID counter never rolled over "
                f"(asid-next went {before['asid_next']} -> "
                f"{second['asid_next']}); raise the rounds, this run did "
                "not reach what it is for")
    if second["pages_live"] > first["pages_live"]:
        return ("pages in use grew during the second phase of identical "
                f"work: {first['pages_live']} -> {second['pages_live']}")
    return None


if __name__ == "__main__":
    sys.exit(main())
