#!/usr/bin/env python3
"""Controls for the UART driver's DDB postmortem walk, with no QEMU in the room.

An ordinary lane never expects its guest to reach the debugger, so a `ddb> `
in its capture means the run stopped somewhere it cannot continue from. The
driver answers that prompt with a short read-only walk and reports the stall
(GitHub issue #511). Before it did, the 2026-09-07 multicore exec assertion
produced a lane whose last captured line was `ddb>` and whose verdict was a
timeout: every answer was sitting behind a prompt nobody asked.

#511's acceptance asks that a control reach the trigger WITHOUT a stall to
reproduce. The first version of this file did that with real sockets, real
subprocesses and real wall-clock budgets, and it was wrong about where that
belonged: `langcheck` is a static policy lane whose every other member is
deterministic, and this one asked a four-core hosted runner to hold seven
concurrent multi-second timing games while `allbuild` compiled beside it. It
cost issue #525 and two stabilisation attempts and was still red.

So the driver is driven IN PROCESS here. `run_kernel_uart_driver.py` reaches
the outside world through exactly two module globals -- `serial` and `time` --
and both are replaced: a pyserial-shaped endpoint scripted by this file, and a
clock that advances only where a real one would block, by the amount it would
block for. The state machine under test is the real one and the budget
arithmetic is the real one, but the whole file runs in milliseconds with no
port, no thread and no subprocess in the timed path. A test of a timeout
should not have to wait for one.

What that gives up is proof that the driver works over a real serial
transport. Every QEMU and RPi5 lane proves that on every run; none of them
proves what is here, which is what the walk does at a prompt and what the
budget does at its end.

The one thing still driven over a real socket is `send_serial_break`, because
what is worth testing about it is its wire behaviour against a QMP server --
one request and one reply, with no capture budget anywhere near it.
"""

import importlib.util
import json
import pathlib
import re
import socket
import sys
import tempfile
import threading

from pass_line import CaseCount, report_pass

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


class Clock:
    """A monotonic clock that only moves where a real one would block.

    The driver's loop is `while time.monotonic() < deadline: connection.read()`,
    so a read returning nothing is the only thing between one iteration and the
    next. Advancing by the read timeout there is exactly what the real pair
    does, and it is what makes a 90-second budget cost no seconds to test.
    """

    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakeUart:
    """A pyserial-shaped endpoint, scripted rather than connected."""

    READ_TIMEOUT = 0.1  # what the driver asks serial_for_url for

    def __init__(self, boot, prompt=None, *, at_prompt=True, answers=True,
                 never_quiet=False):
        self.clock = None
        self.prompt = prompt
        self.answers = answers
        self.never_quiet = never_quiet
        self.pending = bytearray(boot)
        self.refill = bytes(boot)
        if prompt is not None and at_prompt:
            self.pending += prompt
        self.commands = []
        self.written = bytearray()
        self.closed = False

    def broke_in(self):
        """What a delivered serial BREAK does: the debugger prints a prompt."""
        if self.prompt is not None:
            self.pending += self.prompt

    def read(self, size):
        if self.never_quiet and not self.pending:
            # A guest that keeps talking still takes time to say the next
            # thing. Without this the clock never moves and the deadline never
            # arrives, which would be a property of the fake rather than of a
            # guest.
            self.clock.sleep(self.READ_TIMEOUT)
            self.pending += self.refill
        if self.pending:
            chunk = bytes(self.pending[:size])
            del self.pending[:size]
            return chunk
        # A real read blocks for its whole timeout before returning empty.
        self.clock.sleep(self.READ_TIMEOUT)
        return b""

    def write(self, data):
        self.written += data
        while b"\n" in self.written:
            line, _, rest = self.written.partition(b"\n")
            self.written = bytearray(rest)
            name = bytes(line.strip())
            self.commands.append(name)
            if self.answers and self.prompt is not None:
                # A command this file has no answer for gets a bare prompt
                # back. Inventing a plausible kernel line for it would be a
                # line nothing emits, which is its own defect (scripts/
                # check_kernel_log_expectations.py), and check_walk reports
                # the gap by name anyway.
                self.pending += ANSWERS.get(name, b"") + self.prompt

    def close(self):
        self.closed = True


class FakeSerial:
    """The two names the driver uses out of the `serial` package."""

    class SerialException(Exception):
        pass

    def __init__(self, endpoint):
        self.endpoint = endpoint

    def serial_for_url(self, url, **kwargs):
        return self.endpoint


class Outcome:
    def __init__(self, verdict, elapsed, uart, walk_log, breaks):
        self.verdict = verdict          # "" when the driver returned 0
        self.elapsed = elapsed
        self.uart = uart
        self.walk_log = walk_log
        self.breaks = breaks

    @property
    def commands(self):
        return self.uart.commands


def drive(driver, uart, workdir, *, timeout, qmp_port=None,
          break_reaches_guest=True, break_failure=""):
    """Run the driver's own main() against a scripted endpoint.

    Returns what the lane would have reported, plus how far the clock moved,
    which is what says whether the walk ended the run early or the budget did.
    """
    clock = Clock()
    uart.clock = clock
    breaks = []

    def send_serial_break(port, chardev, budget):
        breaks.append((port, chardev))
        if break_failure:
            return break_failure
        if break_reaches_guest:
            uart.broke_in()
        return ""

    fixture = workdir / "ash.stdin"
    fixture.write_text("echo hello\n", encoding="ascii")
    expected = workdir / "ash.expected"
    expected.write_text("hello\n", encoding="ascii")
    walk_log = workdir / "ddb-postmortem.log"
    argv = [
        str(DRIVER),
        "--port", "socket://127.0.0.1:1",
        "--log", str(workdir / "uart.log"),
        "--stdin", str(fixture), "--expected", str(expected),
        "--timeout", str(timeout), "--ash-only", "--validate-ash",
        "--postmortem-log", str(walk_log),
    ]
    if qmp_port is not None:
        argv += ["--qmp-port", str(qmp_port)]

    saved = (driver.serial, driver.time, driver.send_serial_break, sys.argv)
    driver.serial = FakeSerial(uart)
    driver.time = clock
    driver.send_serial_break = send_serial_break
    sys.argv = argv
    started = clock.monotonic()
    try:
        driver.main()
        verdict = ""
    except RuntimeError as error:
        verdict = f"FAIL kernel UART driver: {error}"
    finally:
        driver.serial, driver.time, driver.send_serial_break, sys.argv = saved
    return Outcome(verdict, clock.monotonic() - started, uart, walk_log, breaks)


def check_walk(driver) -> list[str]:
    """A prompt fires the documented walk and ends the lane with its findings."""
    failures = []
    documented = list(driver.POSTMORTEM_COMMANDS)
    budget = 90.0  # the lanes' own default, so the arithmetic is theirs
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        uart = FakeUart(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT)
        result = drive(driver, uart, workdir, timeout=budget)

        if result.commands != documented:
            failures.append(f"the walk sent {result.commands!r}, not the "
                            f"documented {documented!r}")
        if not result.verdict:
            failures.append("a guest stopped at a debugger prompt was reported "
                            "as a passing lane")
        if "stopped at a DDB prompt" not in result.verdict:
            failures.append(f"the verdict did not name the stall: "
                            f"{result.verdict!r}")
        if "listener ready port=8080" not in result.verdict:
            failures.append("the verdict did not name the last line the guest "
                            "managed before the prompt")
        # The whole saving: a stall found early must cost seconds, not the
        # entire budget.
        if result.elapsed >= budget:
            failures.append(f"the lane spent its whole {budget:.0f}s budget "
                            f"({result.elapsed:.1f}s) instead of ending at the "
                            "prompt")
        if not result.walk_log.exists():
            failures.append("no transcript was left for the artifacts")
        else:
            walk = result.walk_log.read_bytes()
            if not walk.startswith(driver.DDB_PROMPT):
                failures.append("the transcript does not start at the prompt "
                                "that fired the walk")
            unanswerable = [name.decode("ascii") for name in documented
                            if name not in ANSWERS]
            if unanswerable:
                failures.append("this control has no DDB answer to play for "
                                + ", ".join(unanswerable))
            missing = [name.decode("ascii") for name in documented
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
        uart = FakeUart(BOOT_FIRST + BOOT_LAST, None)
        result = drive(driver, uart, workdir, timeout=90.0)
        if not result.verdict:
            failures.append("a capture that never completed was reported as "
                            "passing")
        if "DDB" in result.verdict or "ddb" in result.verdict:
            failures.append("ordinary boot output was reported as a stall: "
                            f"{result.verdict!r}")
        if "budget" not in result.verdict:
            failures.append("the ordinary timeout diagnosis was not given")
        if result.walk_log.exists():
            failures.append("a transcript was left for a lane that never "
                            "reached a prompt")
        if result.breaks:
            failures.append("a BREAK was asked for on a lane with no monitor")
    return failures


def check_silence_break(driver) -> list[str]:
    """A guest that stopped gets a BREAK, and the prompt it produces is walked."""
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        uart = FakeUart(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT,
                        at_prompt=False)
        result = drive(driver, uart, workdir, timeout=90.0, qmp_port=4444)
        if [chardev for _, chardev in result.breaks] != [driver.QMP_CHARDEV]:
            failures.append(f"the driver asked for {result.breaks!r} rather "
                            f"than one BREAK on {driver.QMP_CHARDEV!r}")
        if result.commands != list(driver.POSTMORTEM_COMMANDS):
            failures.append("the prompt the BREAK produced was walked as "
                            f"{result.commands!r}")
        if not result.walk_log.exists():
            failures.append("a BREAK that reached the debugger left no "
                            "transcript")
        if "stopped at a DDB prompt" not in result.verdict:
            failures.append(f"the verdict did not name the stall: "
                            f"{result.verdict!r}")
    return failures


def check_unanswered_break(driver) -> list[str]:
    """A BREAK that produces no prompt is the finding #509 could not name."""
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        uart = FakeUart(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT,
                        at_prompt=False)
        result = drive(driver, uart, workdir, timeout=90.0, qmp_port=4444,
                       break_reaches_guest=False)
        if not result.breaks:
            failures.append("no BREAK was asked for a guest that had stopped")
        if "it was not running" not in result.verdict:
            failures.append("a delivered BREAK that produced no prompt was not "
                            f"reported as the finding it is: {result.verdict!r}")
        if result.walk_log.exists():
            failures.append("a transcript was left for a walk that never "
                            "happened")
    return failures


def check_unreachable_monitor(driver) -> list[str]:
    """A monitor that cannot be reached names itself and takes nothing away.

    This is the branch that decides whether the diagnosis is safe to arm on
    every run: it must ADD to the lane's own timeout report, never replace it.
    """
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        uart = FakeUart(BOOT_FIRST + BOOT_LAST, driver.DDB_PROMPT,
                        at_prompt=False)
        result = drive(driver, uart, workdir, timeout=90.0, qmp_port=4444,
                       break_failure="QMP on port 4444 was unreachable: refused")
        if "could not be asked" not in result.verdict:
            failures.append("an unreachable monitor said nothing: "
                            f"{result.verdict!r}")
        if "budget" not in result.verdict:
            failures.append("a failed BREAK replaced the lane's own timeout "
                            "diagnosis instead of adding to it")
    return failures


def check_talking_guest(driver) -> list[str]:
    """A guest still producing output at its deadline must not be broken into."""
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        workdir = pathlib.Path(raw)
        uart = FakeUart(BOOT_FIRST, driver.DDB_PROMPT, at_prompt=False,
                        never_quiet=True)
        result = drive(driver, uart, workdir, timeout=90.0, qmp_port=4444)
        if result.breaks:
            failures.append("a guest that was still talking at its deadline was "
                            "stopped by its own diagnosis")
        if result.walk_log.exists():
            failures.append("a transcript was left for a guest that never "
                            "stopped")
        if "still sending" not in result.verdict:
            failures.append("a slow guest was not reported as slow: "
                            f"{result.verdict!r}")
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


class FakeQmp:
    """QEMU's monitor, far enough to answer one chardev-send-break."""

    def __init__(self, refuse=False, greet=True):
        self.refuse = refuse
        self.greet = greet
        self.breaks = []
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(10.0)
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
            if not self.greet:
                return
            stream.write(b'{"QMP": {"version": {}, "capabilities": []}}\n')
            while True:
                try:
                    line = stream.readline()
                except OSError:
                    return
                if not line:
                    return
                request = json.loads(line)
                if request.get("execute") == "chardev-send-break":
                    if self.refuse:
                        stream.write(b'{"error": {"class": "DeviceNotFound"}}\n')
                        continue
                    self.breaks.append(request["arguments"]["id"])
                stream.write(b'{"return": {}}\n')


def free_port() -> int:
    """A port with nothing behind it, for the unreachable case."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def check_qmp_wire(driver) -> list[str]:
    """The BREAK request itself, against a monitor that speaks QMP.

    The in-process cases prove WHEN the driver asks. This proves the asking is
    a `chardev-send-break` a QEMU monitor accepts, and that every way it can go
    wrong comes back as a sentence rather than an exception -- the whole point
    being that a diagnosis must never replace the failure it was called to
    explain.
    """
    failures = []
    with FakeQmp() as qmp:
        problem = driver.send_serial_break(qmp.port, driver.QMP_CHARDEV, 5.0)
    if problem:
        failures.append(f"a monitor that accepts the break reported {problem!r}")
    if qmp.breaks != [driver.QMP_CHARDEV]:
        failures.append(f"the monitor was asked for {qmp.breaks!r} rather than "
                        f"one break on {driver.QMP_CHARDEV!r}")

    with FakeQmp(refuse=True) as qmp:
        problem = driver.send_serial_break(qmp.port, driver.QMP_CHARDEV, 5.0)
    if "refused" not in problem:
        failures.append(f"a refused break was not reported as one: {problem!r}")

    with FakeQmp(greet=False) as qmp:
        problem = driver.send_serial_break(qmp.port, driver.QMP_CHARDEV, 5.0)
    if "no greeting" not in problem:
        failures.append("a monitor that accepted a connection and said nothing "
                        f"was not distinguished: {problem!r}")

    problem = driver.send_serial_break(free_port(), driver.QMP_CHARDEV, 1.0)
    if "unreachable" not in problem:
        failures.append(f"an unreachable monitor was not named: {problem!r}")
    return failures


def check_read_only(driver) -> list[str]:
    """The walk against the DDB inventory, which is the surface it drives.

    The cases above read the command list out of the driver, so they cannot say
    anything about what is IN that list -- they would agree with any list at
    all. This is the half that can: the inventory says which commands the
    dispatcher really has, which take arguments the walk does not supply, and
    which are test-only. What it protects is the property the walk is for. A
    stalled guest is evidence, and `continue` spends it.

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
        #
        # Bracketed groups are removed whole rather than word by word. An
        # optional argument can contain a space -- `bt [PID|cpu N]` is one
        # choice, not an optional `[PID|cpu` and a required `N]` -- and
        # splitting on spaces first read that as a command the walk could not
        # call. GitHub issue #505 is what found it.
        required = re.sub(r"\[[^\]]*\]", " ", usage[name]).split()[1:]
        if required:
            failures.append(f"{name} requires {' '.join(required)}, which the "
                            "walk sends no way to supply")
    # The BREAK names a chardev, and the lane names the same one when it starts
    # QEMU. Nothing else connects the two, and a mismatch is invisible until a
    # stall -- the one moment nobody is watching.
    for lane in sorted((REPO_ROOT / "scripts").glob("run_kernel_*.sh")):
        text = lane.read_text()
        if "--qmp-port" not in text:
            continue
        named = re.findall(r"-chardev \"socket,id=([A-Za-z0-9_]+)", text)
        if driver.QMP_CHARDEV not in named:
            failures.append(f"{lane.name} asks the driver for a BREAK but gives "
                            f"QEMU {named or 'no'} chardev, not "
                            f"{driver.QMP_CHARDEV!r}")
    if b"continue" in driver.POSTMORTEM_COMMANDS:
        failures.append("the walk resumes the guest, destroying the state the "
                        "next question would have asked about")
    return failures


CHECKS = (
    ("walk", check_walk),
    ("ordinary-output", check_ordinary_output),
    ("silence-break", check_silence_break),
    ("unanswered-break", check_unanswered_break),
    ("unreachable-monitor", check_unreachable_monitor),
    ("talking-guest", check_talking_guest),
    ("partial-walk", check_partial_walk),
    ("qmp-wire", check_qmp_wire),
    ("read-only", check_read_only),
)


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def main() -> int:
    driver = load_driver()
    failures = []
    # Sequential on purpose. Each case swaps the driver's `serial`, `time` and
    # break sender, which are module globals; running two side by side would be
    # sharing one driver between two scripts. It costs nothing now that no case
    # waits for a clock.
    for name, check in CHECKS:
        CASES.note()
        for failure in check(driver):
            failures.append(f"{name}: {failure}")
    for failure in failures:
        print(f"ERROR\tddb-postmortem: {failure}")
    if failures:
        print("FAIL ddb-postmortem: an ordinary lane does not answer a "
              "debugger prompt correctly")
        return 1
    report_pass(
        "ddb-postmortem",
        "a debugger prompt fires the read-only walk in order, ends the "
        "lane with what it found, ordinary output fires nothing, every "
        "command in it is a read-only view the debugger answers with no "
        "argument, and a guest that stops without reaching the debugger "
        "has a BREAK asked for on its behalf while one still talking "
        "does not",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
