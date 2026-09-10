#!/usr/bin/env python3
"""Controls for the RPi5 DDB driver, over a pty standing in for the board.

The driver's job after `ddb: continuing` is to get one command into a shell
that has just been resumed and see its echo come back. That command used to be
written once, with no recovery if it was dropped, and the give-up said
`RPi5 workload did not resume` either way (GitHub issue #515).

The retry that replaced it can only be exercised by SILENCE, which is the one
thing a passing hardware run never produces -- ten consecutive lane runs on
2026-09-05 all answered the first command, so the board cannot tell anyone
whether the retry works. Worse, the retry is easy to disable by accident: the
first draft of it sat below an `if not chunk: continue` in the read loop, so
it could only fire while the shell was already talking, which is exactly when
it is not needed.

So the board is replaced by a pty and the shell is scripted. One case answers
the first command, one ignores the first and answers the second, and one never
answers at all and is required to fail with the attempt count in the message.
"""

import os
import pty
import re
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
DRIVER = ROOT / "scripts" / "run_kernel_ddb_rpi5_driver.py"

PROMPT = b"ddb> "
BANNER = (b"\nddb: interrupt-safe UART debugger\n"
          b"ddb: world-stop complete mask=0x0000000000000002\n"
          b"ddb: break seq=1 cpu=0 elr=0x00000000400103a0 "
          b"sp_el0=0x000000007ffffdf0\n")

# The exact lines the driver asserts on, taken from a real capture so a
# change to either side shows up here rather than only on the board.
REPLIES = {
    b"xkfault": (b"\nddb: xk address=0x0000000800000000 count=1\n"
                 b"ddb: xk fault address=0x0000000800000000\n"),
    b"events": (b"\nddb: events cpu=0 count=2 damaged=0 overwritten=0\n"
                b"ddb: event seq=1 cpu=0 id=0x0000000000000201 "
                b"a=0x000000000000000a b=0x0000000000000025 "
                b"c=0x0000000000000023 d=0x0000000000000004\n"
                b"ddb: event seq=2 cpu=0 id=0x0000000000000101 "
                b"a=0x0000000000000500 b=0x0000000000000000 "
                b"c=0x0000000000000000 d=0x0000000000000000\n"),
    b"bt": (b"\nddb: bt source=cpu cpu=0 pid=37 "
            b"stack=0x00000000005bc000..0x00000000005c0000\n"
            b"ddb: bt frame=0 pc=0x00000000400103a0 boundary=user\n"
            b"ddb: bt stop=user-boundary fp=0x000000007ffffa40\n"),
    # GitHub issue #529. A board mid-boot has nothing waiting on anything,
    # which is the answer the driver has to accept as well as a stall: it
    # asserts the header and the summary, not that an edge was found.
    b"wait": (b"\nddb: wait current=37 state=running reason=none awaited=0\n"
              b"ddb: wait edges=0 blocked=0 unknown=0 truncated=0\n"),
}
# What the board actually produces: the command's output on its own line,
# then the next prompt. The `ddb: continuing` line supplies the newline in
# front of it.
RESUME_ECHO = b"ddb-resume-ok\r\n/ # "


def retry_seconds() -> float:
    """Read the driver's own retry interval, so this does not go stale."""
    text = DRIVER.read_text(encoding="ascii")
    match = re.search(r"^RESUME_RETRY_SECONDS = ([0-9.]+)$", text, re.M)
    if match is None:
        raise SystemExit("the driver no longer declares RESUME_RETRY_SECONDS")
    return float(match.group(1))


def scripted_board(master: int, proc, answer_on_attempt: int, budget: float,
                   answer_wake: bool = True, restore_console: bool = True):
    """Play the kernel side; return how many resume commands were seen.

    The driver's opening move is a newline whose only job is to make the
    kernel record a process UART-wake, and it now waits to be answered before
    breaking in. `answer_wake=False` plays a board that never answers it,
    which is the case the driver has to attribute correctly rather than
    reporting as a ring-retention defect.

    `restore_console=False` plays the kernel this driver's newest assertion
    exists for (GitHub issue #531): one that continues normally and leaves the
    console spinning. Everything else about that boot is correct, which is why
    it needs a control -- a lane that cannot fail on it is a lane that could
    not have seen the defect.

    The BREAK itself is not observable from the master end of a pty, so the
    debugger banner follows the acknowledgement by a short delay instead --
    the same ordering a real board produces.
    """
    pending = b""
    resume_seen = 0
    continued = False
    acked = False
    announce_at = None
    announced = False
    deadline = time.monotonic() + budget
    while proc.poll() is None and time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.05)
        if announce_at is not None and not announced \
                and time.monotonic() >= announce_at:
            os.write(master, BANNER + PROMPT)
            announced = True
        if not readable:
            continue
        try:
            pending += os.read(master, 4096)
        except OSError:
            break
        if not acked:
            acked = True
            if not answer_wake:
                pending = b""
                continue
            # What a shell answers an empty command line with.
            os.write(master, b"\r\n")
            announce_at = time.monotonic() + 0.2
            pending = b""
            continue
        while b"\n" in pending:
            line, _, pending = pending.partition(b"\n")
            command = line.strip()
            if command in REPLIES:
                os.write(master, REPLIES[command] + PROMPT)
            elif command == b"continue":
                # The real kernel prints the restored console state after the
                # loop it leaves, so it lands after `continuing`.
                resumed_line = (b"ddb: console tx=queued\n"
                                if restore_console else b"")
                os.write(master, b"\nddb: continuing\n" + resumed_line)
                continued = True
            elif command == b"echo ddb-resume-ok" and continued:
                resume_seen += 1
                # answer_on_attempt == 0 means never answer.
                if answer_on_attempt and resume_seen >= answer_on_attempt:
                    os.write(master, RESUME_ECHO)
    return resume_seen


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def run_case(label, answer_on_attempt, timeout, expect_ok, needles,
             answer_wake=True, restore_console=True):
    CASES.note()
    master, slave = pty.openpty()
    try:
        port = os.ttyname(slave)
        with tempfile.NamedTemporaryFile(suffix=".log") as log:
            proc = subprocess.Popen(
                [sys.executable, str(DRIVER), "--port", port,
                 "--log", log.name, "--timeout", str(timeout)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            attempts = scripted_board(master, proc, answer_on_attempt,
                                      timeout + 10, answer_wake,
                                      restore_console)
            stdout, stderr = proc.communicate(timeout=30)
    finally:
        os.close(master)
        os.close(slave)

    output = stdout + stderr
    if (proc.returncode == 0) != expect_ok:
        print(f"FAIL ddb-rpi5-driver control: {label} exited "
              f"{proc.returncode}, expected {'0' if expect_ok else 'nonzero'}"
              f"\n{output}")
        return None
    for needle in needles:
        if needle not in output:
            print(f"FAIL ddb-rpi5-driver control: {label} did not report "
                  f"{needle!r}\n{output}")
            return None
    return attempts


def main() -> int:
    retry = retry_seconds()

    # The board's own shape: the shell answers the first command.
    attempts = run_case(
        "a shell that answers at once", 1, 6.0, True,
        ["PASS kernel/rpi5 ddb:", "resume-attempts=1", "resume-echoed="])
    if attempts is None:
        return 1
    if attempts != 1:
        print(f"FAIL ddb-rpi5-driver control: a prompt answer took "
              f"{attempts} commands")
        return 1

    # The case the board cannot produce: the first command is dropped and
    # nothing else happens on the wire. The retry has to fire during that
    # silence, which is what the read loop must not skip.
    budget = retry * 3 + 6.0
    attempts = run_case(
        "a dropped first command", 2, budget, True,
        ["PASS kernel/rpi5 ddb:", "resume-echoed="])
    if attempts is None:
        return 1
    if attempts < 2:
        print("FAIL ddb-rpi5-driver control: the resume command was not "
              f"retried during silence ({attempts} sent). A retry that only "
              "fires while the shell is talking is not a retry.")
        return 1

    # A workload that really did not resume: the give-up must say how many
    # commands went out, so it is a verdict rather than one word.
    silent_budget = retry * 2 + 3.0
    attempts = run_case(
        "a workload that never answers", 0, silent_budget, False,
        ["resume command(s) went out and no echo came back",
         "resume-echoed=never", "timeline:"])
    if attempts is None:
        return 1
    if attempts < 2:
        print(f"FAIL ddb-rpi5-driver control: only {attempts} resume "
              f"command(s) went out in {silent_budget:.1f}s")
        return 1

    # A board that never answers the byte the wake event depends on. The
    # driver must say that, and must NOT go on to report a ring-retention
    # defect about a ring nothing was given to retain (GitHub issue #519).
    if run_case("a board that never answers the wake byte", 1, 6.0, False,
                ["did not answer the byte", "wake-acked=never",
                 "NOT a diagnostic-ring retention defect"],
                answer_wake=False) is None:
        return 1

    # A kernel that resumes correctly in every other respect and leaves the
    # console spinning (GitHub issue #531). This is the whole reason that
    # assertion exists: the loss is invisible on this lane, which ends at the
    # shell rather than at the boot's own `console: tx spin` measurement, so
    # without a failure here the fix would be as unobservable as the defect.
    if run_case("a resume that leaves the console spinning", 1, 6.0, False,
                ["did not restore the console transmit queue"],
                restore_console=False) is None:
        return 1

    # A board that answers `wait` with something the derivation could not have
    # produced (GitHub issue #529). The driver asserts the shape of the header
    # and of the summary, so a rendering that stops naming its states, or
    # stops summarising at all, has to fail here -- otherwise it would pass
    # quietly on a lane whose real snapshot happens to have nothing waiting.
    intact_wait = REPLIES[b"wait"]
    summary = b"ddb: wait edges=0 blocked=0 unknown=0 truncated=0\n"
    REPLIES[b"wait"] = b"\nddb: wait current=37\n" + summary
    outcome = run_case("a wait header the derivation could not produce", 1,
                       6.0, False, ["did not render the wait header"])
    if outcome is not None:
        REPLIES[b"wait"] = (b"\nddb: wait current=37 state=running "
                            b"reason=none awaited=0\n")
        outcome = run_case("a wait listing with no summary", 1, 6.0, False,
                           ["did not render the wait summary"])
    REPLIES[b"wait"] = intact_wait
    if outcome is None:
        return 1

    report_pass(
        "ddb-rpi5-driver controls",
        "the wake byte is acknowledged before the BREAK and a board "
        "that never answers it says so, an immediate resume takes one "
        "command, a dropped first command is retried during silence, a "
        "workload that never answers fails with the attempt count, a "
        "resume that leaves the console spinning fails, and a wait view "
        "missing its header or its summary fails",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
