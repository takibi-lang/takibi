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
    argument the walk cannot supply, and does not resume the guest; and
  * a guest that stops WITHOUT reaching the debugger has one asked for on its
    behalf -- a real QMP `chardev-send-break` -- while a guest still talking at
    its deadline does not, which is the trigger reverted in 3f86b75e made
    harmless by moving it to the end of the budget.

Nothing here covers a prompt split across two reads, because the driver counts
prompts in the whole accumulated capture rather than in one read -- there is no
window for a split to fall outside of.
"""

import concurrent.futures
import importlib.util
import json
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DRIVER = REPO_ROOT / "scripts" / "run_kernel_uart_driver.py"

# The capture budget the stopped-guest cases run under. Everything the driver
# decides with is derived from it -- when it gives up, how long it waits for a
# prompt, and how much silence counts as stopped -- so a short one runs the
# same shape as a lane's 90 or 240 and keeps this file inside langcheck.
BUDGET = 8.0

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
            self._answer(connection)

    def _answer(self, connection):
        """One canned reply per command line, then a fresh prompt."""
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
                # A command this file has no answer for gets a bare prompt
                # back. Inventing a plausible kernel line for it would be a
                # line nothing emits, which is its own defect (scripts/
                # check_kernel_log_expectations.py), and check_walk reports
                # the gap by name anyway.
                connection.sendall(ANSWERS.get(name, b"") + self.prompt)


def run_driver(port: int, timeout: float, workdir: pathlib.Path,
               postmortem: bool = True, qmp_port: int | None = None):
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
    if qmp_port is not None:
        argv += ["--qmp-port", str(qmp_port)]
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
        uart_log = workdir / "uart.log"
        if not uart_log.exists() or BOOT_LAST not in uart_log.read_bytes():
            failures.append("the raw UART capture lost the last boot line "
                            "before the prompt")
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
    if "listener ready port=8080" not in whole:
        failures.append("a complete verdict did not name the last line before "
                        "the prompt")

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


class FakeQmp:
    """QEMU's monitor, far enough to answer one chardev-send-break."""

    def __init__(self, refuse: bool = False):
        self.refuse = refuse
        self.breaks: list[str] = []
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(30.0)
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
            stream = connection.makefile("rwb", buffering=0)
            stream.write(b'{"QMP": {"version": {}, "capabilities": []}}\n')
            while True:
                line = stream.readline()
                if not line:
                    return
                request = json.loads(line)
                if request.get("execute") == "chardev-send-break":
                    if self.refuse:
                        stream.write(b'{"error": {"class": "DeviceNotFound", '
                                     b'"desc": "no such chardev"}}\n')
                        continue
                    self.breaks.append(request["arguments"]["id"])
                stream.write(b'{"return": {}}\n')


class SilentGuest(FakeGuest):
    """A guest that stops mid-boot: output, then nothing, then DDB if broken in.

    The prompt is withheld until this file is told the BREAK arrived, which is
    what makes the control an end-to-end one rather than two halves that agree
    by construction: the walk only happens if the driver really asked QEMU.
    """

    def __init__(self, transcript: bytes, prompt: bytes):
        super().__init__(transcript, prompt)
        self.broken_in = threading.Event()

    def _serve(self):
        try:
            connection, _ = self.listener.accept()
        except OSError:
            return
        with connection:
            connection.sendall(self.transcript)
            if not self.broken_in.wait(timeout=60.0):
                return
            connection.sendall(self.prompt)
            connection.settimeout(20.0)
            self._answer(connection)


class ChattyGuest(FakeGuest):
    """A guest that is merely slow: it keeps producing output to the end."""

    def _serve(self):
        try:
            connection, _ = self.listener.accept()
        except OSError:
            return
        with connection:
            try:
                while True:
                    connection.sendall(self.transcript)
                    time.sleep(0.5)
            except OSError:
                return


def check_silence_break(driver) -> list[str]:
    """A guest that stopped gets a BREAK; one still talking does not."""
    failures = []
    # Short enough to run in langcheck, and the driver derives everything it
    # decides with from this budget, so the shape is the lanes' own.
    budget = BUDGET
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        with SilentGuest(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT) as guest, \
                FakeQmp() as qmp:
            waiter = threading.Thread(
                target=lambda: (guest.broken_in.set()
                                if wait_for_break(qmp) else None),
                daemon=True)
            waiter.start()
            finished, _, walk_log = run_driver(
                guest.port, budget, workdir, qmp_port=qmp.port)
        if qmp.breaks != [driver.QMP_CHARDEV]:
            failures.append(
                f"the driver asked for {qmp.breaks!r} rather than one BREAK on "
                f"{driver.QMP_CHARDEV!r}")
        if guest.commands != list(driver.POSTMORTEM_COMMANDS):
            failures.append(
                f"the prompt the BREAK produced was walked as {guest.commands!r}")
        if not walk_log.exists():
            failures.append("a BREAK that reached the debugger left no "
                            "transcript")
        report = finished.stdout + finished.stderr
        if "stopped at a DDB prompt" not in report:
            failures.append(f"the verdict did not name the stall: {report!r}")
    return failures


def check_silence_break_unanswered(driver) -> list[str]:
    """A BREAK that produces no prompt is the finding #509 could not name."""
    failures = []
    budget = BUDGET
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        with SilentGuest(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT) as guest, \
                FakeQmp() as qmp:
            # Nothing sets guest.broken_in, so the BREAK is delivered and the
            # guest never answers: a kernel that was not running at all.
            finished, _, walk_log = run_driver(
                guest.port, budget, workdir, qmp_port=qmp.port)
        report = finished.stdout + finished.stderr
        if qmp.breaks != [driver.QMP_CHARDEV]:
            failures.append("no BREAK was asked for a guest that had stopped")
        if "it was not running" not in report:
            failures.append(
                "a delivered BREAK that produced no prompt was not reported as "
                f"the finding it is: {report!r}")
        if walk_log.exists():
            failures.append("a transcript was left for a walk that never "
                            "happened")
    return failures


def check_unreachable_monitor(driver) -> list[str]:
    """A monitor that cannot be reached names itself and takes nothing away.

    This is the branch that decides whether the diagnosis is safe to arm on
    every run: it must ADD to the lane's own timeout report, never replace it.
    """
    failures = []
    budget = BUDGET
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        with SilentGuest(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT) as guest:
            finished, _, _ = run_driver(guest.port, budget, workdir,
                                        qmp_port=find_dead_port())
        report = finished.stdout + finished.stderr
        if "could not be asked" not in report:
            failures.append(f"an unreachable monitor said nothing: {report!r}")
        if "budget" not in report:
            failures.append("a failed BREAK replaced the lane's own timeout "
                            "diagnosis instead of adding to it")
    return failures


def check_talking_guest(driver) -> list[str]:
    """A guest still producing output at its deadline must not be broken into."""
    failures = []
    budget = BUDGET
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        with ChattyGuest(BOOT_FIRST, driver.DDB_PROMPT) as guest, \
                FakeQmp() as qmp:
            finished, _, walk_log = run_driver(
                guest.port, budget, workdir, qmp_port=qmp.port)
        if qmp.breaks:
            failures.append("a guest that was still talking at its deadline "
                            "was stopped by its own diagnosis")
        if walk_log.exists():
            failures.append("a transcript was left for a guest that never "
                            "stopped")
        report = finished.stdout + finished.stderr
        if "still sending" not in report:
            failures.append(f"a slow guest was not reported as slow: {report!r}")
    return failures


def wait_for_break(qmp: FakeQmp) -> bool:
    """True once the monitor has recorded one BREAK, within a bounded wait."""
    for _ in range(600):
        if qmp.breaks:
            return True
        time.sleep(0.05)
    return False


def find_dead_port() -> int:
    """A port with nothing behind it, for the unreachable-monitor case."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def check_read_only(driver) -> list[str]:
    """The walk against the DDB inventory, which is the surface it drives.

    The end-to-end control above reads the command list out of the driver, so
    it cannot say anything about what is IN that list -- it would agree with
    any list at all. This is the half that can: the inventory says which
    commands the dispatcher really has, which take arguments the walk does not
    supply, and which are test-only. What it protects is the property the walk
    is for. A stalled guest is evidence, and `continue` spends it.

    The chardev the BREAK names is checked here for the same reason: it is the
    other end of a pairing nothing else holds together.
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
    # The BREAK names a chardev, and the lane names the same one when it
    # starts QEMU. Nothing else connects the two, and a mismatch is invisible
    # until a stall -- the one moment nobody is watching.
    for lane in sorted((REPO_ROOT / "scripts").glob("run_kernel_*.sh")):
        text = lane.read_text()
        if "--qmp-port" not in text:
            continue
        named = re.findall(r"-chardev \"socket,id=([A-Za-z0-9_]+)", text)
        if driver.QMP_CHARDEV not in named:
            failures.append(
                f"{lane.name} asks the driver for a BREAK but gives QEMU "
                f"{named or 'no'} chardev, not {driver.QMP_CHARDEV!r}")
    if b"continue" in driver.POSTMORTEM_COMMANDS:
        failures.append("the walk resumes the guest, destroying the state the "
                        "next question would have asked about")
    return failures


CHECKS = (
    ("walk", check_walk),
    ("ordinary-output", check_ordinary_output),
    ("partial-walk", check_partial_walk),
    ("read-only", check_read_only),
    ("silence-break", check_silence_break),
    ("unanswered-break", check_silence_break_unanswered),
    ("unreachable-monitor", check_unreachable_monitor),
    ("talking-guest", check_talking_guest),
)


def main() -> int:
    driver = load_driver()
    # Concurrently, because four of these have to spend a whole capture budget
    # each -- there is no way to observe a give-up branch without reaching it
    # -- and they share nothing: every case binds its own ephemeral ports and
    # writes into its own temporary directory. Sequentially this file costs
    # 54s, which is more than the whole of langcheck.
    with concurrent.futures.ThreadPoolExecutor(len(CHECKS)) as pool:
        results = [(name, pool.submit(check, driver)) for name, check in CHECKS]
    failures = []
    for name, result in results:
        for failure in result.result():
            failures.append(f"{name}: {failure}")
    for failure in failures:
        print(f"ERROR\tddb-postmortem: {failure}")
    if failures:
        print("FAIL ddb-postmortem: an ordinary lane does not answer a "
              "debugger prompt correctly")
        return 1
    print("PASS ddb-postmortem: a debugger prompt fires the read-only walk in "
          "order, ends the lane with what it found, ordinary output fires "
          "nothing, every command in it is a read-only view the debugger "
          "answers with no argument, and a guest that stops without reaching "
          "the debugger has a BREAK asked for on its behalf while one still "
          "talking does not")
    return 0


if __name__ == "__main__":
    sys.exit(main())
