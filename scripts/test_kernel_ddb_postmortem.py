#!/usr/bin/env python3
"""Controls for the UART driver's DDB postmortem walk, with no QEMU in the room.

An ordinary lane never expects its guest to reach the debugger, so a `ddb> `
in its capture means the run stopped somewhere it cannot continue from. The
driver answers that prompt with a short read-only walk and reports the stall
(GitHub issue #511). Before it did, the 2026-09-07 multicore exec assertion
produced a lane whose last captured line was `ddb>` and whose verdict was a
timeout: every answer was sitting behind a prompt nobody asked.

The property under test is the trigger, and the acceptance condition #511
wrote for it is that a control reaches it WITHOUT a stall to reproduce. So the
guest here is a socket: this file plays the debugger, and checks that

  * a prompt fires the walk, in the documented order, one command per prompt;
  * the walk's transcript is kept where the lane's artifacts are;
  * the lane ends at the prompt rather than at its capture budget, which is
    the whole saving -- a stall found at second 3 of 90 used to cost 90;
  * ordinary boot output does NOT fire it, and leaves no transcript behind to
    read as one; and
  * the message says how far the walk got, for the case where the debugger
    itself stops answering partway; and
  * every command in the walk is one the debugger dispatches, needs no
    argument the walk cannot supply, and does not resume the guest.

Nothing here covers a prompt split across two reads, because the driver counts
prompts in the whole accumulated capture rather than in one read -- there is no
window for a split to fall outside of.
"""

import importlib.util
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DRIVER = REPO_ROOT / "scripts" / "run_kernel_uart_driver.py"

# Real boot lines, kept as separate literals so scripts/
# check_kernel_log_expectations.py checks each against something the kernel
# can emit -- one literal holding two lines is not a line anything emits.
BOOT_FIRST = b"takibi kernel: EL1\r\n"
BOOT_LAST = b"linux socket: listener ready port=8080\r\n"

# What this file answers each walk command with. Real DDB output shapes: the
# `bt` and `sched` lines are the ones copied into #511 from the day they ended
# the #509 investigation.
ANSWERS = {
    b"oops": b"ddb: break seq=1 cpu=0 elr=0x0000000040038a74 sp_el0=0x0\r\n",
    b"intr": b"ddb: intr cpu=0 entry=brk source=1 live_daif=0x3c0 saved_daif=0x0\r\n",
    b"bt": b"ddb: bt frame=1 pc=0x0000000040038a74\r\n",
    b"sched": b"ddb: sched enabled=1 pending=1 current=27 ready=0 running=1 blocked=2\r\n",
    b"current": b"ddb: current pid=27 parent=1 state=2 wait=0\r\n",
    b"ps": b"ddb: ps count=3\r\n",
}


def load_driver():
    spec = importlib.util.spec_from_file_location("uart_driver", DRIVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeGuest:
    """A UART the driver can connect to, playing boot output and then DDB."""

    def __init__(self, transcript: bytes, prompt: bytes | None):
        self.transcript = transcript
        self.prompt = prompt
        self.commands: list[bytes] = []
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(20.0)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.listener.close()
        self.thread.join(timeout=5.0)

    def _serve(self):
        try:
            connection, _ = self.listener.accept()
        except OSError:
            return
        with connection:
            connection.sendall(self.transcript)
            if self.prompt is None:
                # Nothing more to say. The driver is supposed to keep waiting
                # for its own markers here, not to invent a debugger.
                time.sleep(5.0)
                return
            connection.sendall(self.prompt)
            connection.settimeout(20.0)
            pending = bytearray()
            while True:
                try:
                    chunk = connection.recv(256)
                except (socket.timeout, OSError):
                    return
                if not chunk:
                    return
                pending.extend(chunk)
                while b"\n" in pending:
                    line, _, rest = pending.partition(b"\n")
                    pending = bytearray(rest)
                    name = bytes(line.strip())
                    self.commands.append(name)
                    # A command this file has no answer for gets a bare
                    # prompt back. Inventing a plausible kernel line for it
                    # would be a line nothing emits, which is its own defect
                    # (scripts/check_kernel_log_expectations.py), and
                    # check_walk reports the gap by name anyway.
                    connection.sendall(ANSWERS.get(name, b"") + self.prompt)


def run_driver(port: int, timeout: float, workdir: pathlib.Path,
               postmortem: bool = True):
    """The driver against a fake guest, in the cheapest lane shape it has."""
    fixture = workdir / "ash.stdin"
    fixture.write_text("echo hello\n", encoding="ascii")
    expected = workdir / "ash.expected"
    expected.write_text("hello\n", encoding="ascii")
    walk_log = workdir / "ddb-postmortem.log"
    argv = [
        sys.executable, str(DRIVER),
        "--port", f"socket://127.0.0.1:{port}",
        "--log", str(workdir / "uart.log"),
        "--stdin", str(fixture), "--expected", str(expected),
        "--timeout", str(timeout), "--ash-only", "--validate-ash",
    ]
    if postmortem:
        argv += ["--postmortem-log", str(walk_log)]
    started = time.monotonic()
    finished = subprocess.run(argv, capture_output=True, text=True,
                              timeout=timeout + 60.0)
    return finished, time.monotonic() - started, walk_log


def check_walk(driver) -> list[str]:
    """A prompt fires the documented walk and ends the lane with its findings."""
    failures = []
    expected_commands = [name for name in driver.POSTMORTEM_COMMANDS]
    # Far larger than the walk needs, so "it stopped at the prompt" and "it
    # ran out of budget" cannot be confused for one another below.
    budget = 45.0
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        with FakeGuest(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT) as guest:
            finished, elapsed, walk_log = run_driver(
                guest.port, budget, workdir)
        if guest.commands != expected_commands:
            failures.append(
                f"the walk sent {guest.commands!r}, not the documented "
                f"{expected_commands!r}")
        if finished.returncode == 0:
            failures.append("a guest stopped at a debugger prompt was "
                            "reported as a passing lane")
        report = finished.stdout + finished.stderr
        if "stopped at a DDB prompt" not in report:
            failures.append(f"the verdict did not name the stall: {report!r}")
        if "listener ready port=8080" not in report:
            failures.append("the verdict did not name the last line the guest "
                            "managed before the prompt")
        if elapsed >= budget:
            failures.append(
                f"the lane spent its whole {budget:.0f}s budget ({elapsed:.1f}s) "
                "instead of ending at the prompt")
        if not walk_log.exists():
            failures.append("no transcript was left for the artifacts")
        else:
            walk = walk_log.read_bytes()
            if not walk.startswith(driver.DDB_PROMPT):
                failures.append("the transcript does not start at the prompt "
                                "that fired the walk")
            # A walk command with no canned answer here means this control
            # was not updated with the driver, so say that rather than
            # reporting a transcript gap it caused itself.
            unanswerable = [name.decode("ascii") for name in expected_commands
                            if name not in ANSWERS]
            if unanswerable:
                failures.append("this control has no DDB answer to play for "
                                + ", ".join(unanswerable))
            missing = [name.decode("ascii") for name in expected_commands
                       if name in ANSWERS and ANSWERS[name] not in walk]
            if missing:
                failures.append("the transcript is missing the answer to "
                                + ", ".join(missing))
            if BOOT_FIRST in walk:
                failures.append("the transcript carries the whole boot rather "
                                "than the walk")
    return failures


def check_ordinary_output(driver) -> list[str]:
    """Boot output with no prompt in it must leave the trigger alone."""
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        with FakeGuest(BOOT_FIRST + BOOT_LAST, None) as guest:
            finished, _, walk_log = run_driver(guest.port, 3.0, workdir)
        report = finished.stdout + finished.stderr
        if finished.returncode == 0:
            failures.append("a capture that never completed was reported as "
                            "passing")
        if "DDB" in report or "ddb" in report:
            failures.append(
                f"ordinary boot output was reported as a stall: {report!r}")
        if "budget" not in report:
            failures.append("the ordinary timeout diagnosis was not given")
        if walk_log.exists():
            failures.append("a transcript was left for a lane that never "
                            "reached a prompt")
    return failures


def check_partial_walk(driver) -> list[str]:
    """A debugger that stops answering partway still has to say how far it got."""
    failures = []
    whole = driver.postmortem_note(BOOT_FIRST + BOOT_LAST,
                                   len(driver.POSTMORTEM_COMMANDS), "walk.log")
    if "unanswered" in whole:
        failures.append("a complete walk was reported as incomplete")
    if "walk.log" not in whole:
        failures.append("a complete walk did not name its transcript")

    partial = driver.postmortem_note(BOOT_FIRST + BOOT_LAST, 2, "walk.log")
    if "unanswered" not in partial:
        failures.append("a walk that stopped partway was reported as complete")
    if str(len(driver.POSTMORTEM_COMMANDS) - 2) not in partial:
        failures.append("a partial walk did not count what went unanswered")

    none = driver.postmortem_note(BOOT_FIRST + BOOT_LAST, 0, None)
    if "no command was answered" not in none:
        failures.append("a prompt that answered nothing was reported as a walk")
    if "walk.log" in none or "transcript in" in none:
        failures.append("a run with no transcript file named one anyway")

    silent = driver.postmortem_note(b"", 0, None)
    if "(nothing at all)" not in silent:
        failures.append("a guest that said nothing before the prompt named no "
                        "last line")
    return failures


def check_read_only(driver) -> list[str]:
    """The walk against the DDB inventory, which is the surface it drives.

    The end-to-end control above reads the command list out of the driver, so
    it cannot say anything about what is IN that list -- it would agree with
    any list at all. This is the half that can: the inventory says which
    commands the dispatcher really has, which take arguments the walk does not
    supply, and which are test-only. What it protects is the property the walk
    is for. A stalled guest is evidence, and `continue` spends it.
    """
    failures = []
    inventory = json.loads(
        (REPO_ROOT / "kernel" / "DDB_COMMANDS.json").read_text(encoding="ascii"))
    usage = {entry["name"]: entry["usage"] for entry in inventory["public"]}
    hidden = {entry["name"] for entry in inventory["hidden"]}
    for raw in driver.POSTMORTEM_COMMANDS:
        name = raw.decode("ascii")
        if name in hidden:
            failures.append(f"{name} is a hidden test-only command, not a "
                            "read-only view of a stalled guest")
            continue
        if name not in usage:
            failures.append(f"{name} is not a command the debugger dispatches")
            continue
        # The walk sends a bare command and nothing else, so anything with a
        # required argument would be answered with a usage line at best.
        required = [word for word in usage[name].split()[1:]
                    if not word.startswith("[")]
        if required:
            failures.append(
                f"{name} requires {' '.join(required)}, which the walk sends "
                "no way to supply")
    if b"continue" in driver.POSTMORTEM_COMMANDS:
        failures.append("the walk resumes the guest, destroying the state the "
                        "next question would have asked about")
    return failures


def main() -> int:
    driver = load_driver()
    failures = []
    for name, check in (("walk", check_walk),
                        ("ordinary-output", check_ordinary_output),
                        ("partial-walk", check_partial_walk),
                        ("read-only", check_read_only)):
        for failure in check(driver):
            failures.append(f"{name}: {failure}")
    for failure in failures:
        print(f"ERROR\tddb-postmortem: {failure}")
    if failures:
        print("FAIL ddb-postmortem: an ordinary lane does not answer a "
              "debugger prompt correctly")
        return 1
    print("PASS ddb-postmortem: a debugger prompt fires the read-only walk in "
          "order, ends the lane with what it found, ordinary output fires "
          "nothing, and every command in it is a read-only view the debugger "
          "answers with no argument")
    return 0


if __name__ == "__main__":
    sys.exit(main())
