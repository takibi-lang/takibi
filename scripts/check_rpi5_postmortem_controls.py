#!/usr/bin/env python3
"""Controls for the RPi5 runners' own postmortem (GitHub issue #872).

The GEM fixture runner and the shell smoke read the UART themselves, so
#869's request-file path does not reach them; scripts/rpi5_postmortem.py
does. Each case drives the real runner code against a scripted endpoint and
asks what #869's rpi5-early-failure asks of the hwtest lane: one SWD
snapshot taken before the one BREAK, the whole walk (the wait graph
included), the runner's own reason kept, inside the budget -- and nothing
at all for a failure before the kernel was loaded.
"""

import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
from unittest.mock import patch

from pass_line import CaseCount, report_pass
import rpi5_postmortem
import rpi5_swd_snapshot
from run_kernel_uart_driver import DDB_PROMPT, POSTMORTEM_COMMANDS
import run_kernel_gem_tx_rpi5 as gem_tx
import run_kernel_shell_rpi5_smoketest as smoke

CASES = CaseCount()


class Clock:
    """A clock that moves only when the code under test sleeps or reads."""

    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class Debugger:
    """What the board does: a BREAK prints a prompt, each line gets one."""

    def __init__(self, answers=True, clock=None):
        self.clock = clock
        self.events = []
        self.pending = bytearray()
        self.line = bytearray()
        self.answers = answers
        self.commands = []

    def send_break(self):
        self.events.append("break")
        if self.answers:
            self.pending += b"\r\n" + DDB_PROMPT

    def write(self, data):
        for byte in data:
            if byte == 0x0A:
                self.commands.append(bytes(self.line))
                self.pending += bytes(self.line) + b"\r\n(answered)\r\n" + DDB_PROMPT
                self.line.clear()
            else:
                self.line.append(byte)

    def read(self):
        if self.clock is not None:
            self.clock.sleep(0.25)  # what a real read's wait costs
        data, self.pending = bytes(self.pending), bytearray()
        return data


def recording_snapshot(events, *, fail=False):
    def capture(elf, log, phase):
        events.append(f"swd:{phase}")
        if fail:
            raise OSError("fixture: OpenOCD missing")
    return capture


def check_collect():
    failures = []
    for answers, snapshot_fails in ((True, False), (False, False), (True, True)):
        CASES.note()
        with tempfile.TemporaryDirectory() as temporary:
            clock = Clock()
            board = Debugger(answers, clock)
            with patch.object(rpi5_swd_snapshot, "capture",
                              recording_snapshot(board.events, fail=snapshot_fails)):
                started = clock.now
                note = rpi5_postmortem.collect(
                    "fixture.elf", temporary, "fixture reason", send_break=board.send_break,
                    write=board.write, read=board.read, clock=clock)
            label = f"answers={answers} snapshot_fails={snapshot_fails}"
            if board.events != ["swd:before-break", "break"]:
                failures.append(f"{label}: order {board.events!r}")
            if clock.now - started > rpi5_postmortem.POSTMORTEM_CEILING + 1:
                failures.append(f"{label}: took {clock.now - started:.1f}s")
            log = (Path(temporary) / "ddb-postmortem.log").read_bytes()
            if not log.startswith(b"postmortem reason=fixture reason\n"):
                failures.append(f"{label}: log lost the reason")
            if answers:
                if board.commands != list(POSTMORTEM_COMMANDS) or b"wait" not in board.commands:
                    failures.append(f"{label}: walked {board.commands!r}")
                wanted = f"{len(POSTMORTEM_COMMANDS)}/{len(POSTMORTEM_COMMANDS)}"
                if wanted not in note:
                    failures.append(f"{label}: note {note!r}")
            elif board.commands or "no DDB prompt" not in note:
                failures.append(f"{label}: silent board gave {board.commands!r}, {note!r}")
    CASES.note()
    board = Debugger(clock=Clock())

    def refuse():
        raise OSError("fixture: port gone")
    board.send_break = refuse
    with tempfile.TemporaryDirectory() as temporary, \
            patch.object(rpi5_swd_snapshot, "capture", recording_snapshot([])):
        note = rpi5_postmortem.collect("fixture.elf", temporary, "r", send_break=refuse,
                                       write=board.write, read=board.read, clock=Clock())
    if "port gone" not in note:
        failures.append(f"a refused BREAK was hidden: {note!r}")
    return failures


class FakeUart:
    """The Debug Probe port the GEM runner opens, failing the fixture."""

    def __init__(self, board, mode):
        self.board = board
        self.mode = mode
        self.boot = bytearray()
        self.lock = threading.Lock()

    def reset_input_buffer(self):
        with self.lock:
            self.boot = bytearray(f"gem-tx fixture: mode {self.mode}\nFAIL gem-tx: fixture\n".encode())

    def read(self, _size):
        with self.lock:
            data, self.boot = bytes(self.boot), bytearray()
        threading.Event().wait(0.01)
        return data + self.board.read()

    def write(self, data):
        self.board.write(data)

    def send_break(self, _duration):
        self.board.send_break()

    def close(self):
        pass


class FakePeer:
    def __init__(self, *_args, **_kwargs):
        reader, writer = os.pipe()
        os.write(writer, b"READY\n[]\n")
        os.close(writer)
        self.stdout = os.fdopen(reader, "r")
        self.stdin = open(os.devnull, "w")
        self.returncode = None

    def poll(self):
        return None

    def wait(self, timeout=None):
        self.returncode = 0
        return 0


def check_gem_tx():
    failures = []
    for fail_phase in (None, "reset", "load"):
        CASES.note()
        mode = gem_tx.MODES[0]
        board = Debugger()

        def run(command, **_kwargs):
            if fail_phase and fail_phase in command[1]:
                raise gem_tx.subprocess.CalledProcessError(1, command)

        with tempfile.TemporaryDirectory() as temporary, \
                patch("serial.Serial", lambda *_a, **_k: FakeUart(board, mode)), \
                patch.object(gem_tx.subprocess, "Popen", FakePeer), \
                patch.object(gem_tx.subprocess, "run", run), \
                patch.object(gem_tx, "ROOT", Path(temporary)), \
                patch.object(rpi5_swd_snapshot, "capture", recording_snapshot(board.events)):
            elf = Path(temporary) / f"kernel/build/rpi5/kernel-gem-tx-fixture-{mode}.elf"
            elf.parent.mkdir(parents=True)
            elf.write_bytes(b"fixture elf")
            directory = Path(temporary) / mode
            try:
                gem_tx.run_case(mode, "/dev/fixture", directory, "fixture0")
                failures.append(f"{fail_phase}: a failing fixture passed")
                continue
            except (RuntimeError, gem_tx.subprocess.SubprocessError):
                pass
            if fail_phase in ("reset", "load"):
                if board.events:
                    failures.append(f"{fail_phase}: a failure before the kernel ran "
                                    f"asked for a postmortem: {board.events!r}")
                continue
            if board.events != ["swd:before-break", "break"]:
                failures.append(f"after load: order {board.events!r}")
            if board.commands != list(POSTMORTEM_COMMANDS):
                failures.append(f"after load: walked {board.commands!r}")
            log = directory / "ddb-postmortem.log"
            walk = log.read_bytes() if log.exists() else b"(no walk saved)"
            if b"physical fixture reported failure" not in walk.splitlines()[0]:
                failures.append("after load: the walk lost the runner's reason")
    return failures


def check_shell_smoke():
    failures = []
    for console_up in (False, True):
        CASES.note()
        board = Debugger()
        ours, theirs = socket.socketpair()
        stop = threading.Event()

        def miniterm():
            # Ctrl-T b is the console's BREAK; anything else goes to the UART.
            theirs.settimeout(0.05)
            while not stop.is_set():
                try:
                    data = theirs.recv(4096)
                except socket.timeout:
                    data = b""
                if data == b"\x14b":
                    board.send_break()
                elif data:
                    board.write(data)
                answer = board.read()
                if answer:
                    theirs.sendall(answer)

        thread = threading.Thread(target=miniterm, daemon=True)
        thread.start()
        session = smoke.Session(0, ours.fileno())
        if console_up:
            session.transcript += smoke.CONSOLE_UP + b"\r\n"
        try:
            with tempfile.TemporaryDirectory() as temporary, \
                    patch.object(rpi5_swd_snapshot, "capture", recording_snapshot(board.events)):
                note = smoke.postmortem(session, Path(temporary), "fixture.elf", "smoke reason")
        finally:
            stop.set()
            thread.join(timeout=1)
            ours.close()
            theirs.close()
        if not console_up:
            if note is not None or board.events:
                failures.append("a postmortem before miniterm owned the UART")
            continue
        if board.events != ["swd:before-break", "break"]:
            failures.append(f"smoke: order {board.events!r}")
        if board.commands != list(POSTMORTEM_COMMANDS):
            failures.append(f"smoke: walked {board.commands!r}")
        if DDB_PROMPT not in session.transcript:
            failures.append("smoke: the walk is missing from terminal.log")
    # The marker the smoke waits for is the console's own text, not a copy.
    CASES.note()
    import run_kernel_shell_console
    if smoke.CONSOLE_UP != run_kernel_shell_console.BREAK_HINT.encode("ascii"):
        failures.append("the smoke's console marker drifted from the console")
    return failures


def main():
    failures = check_collect() + check_gem_tx() + check_shell_smoke()
    if failures:
        for failure in failures:
            print(f"FAIL rpi5-postmortem: {failure}", file=sys.stderr)
        return 1
    report_pass("rpi5-postmortem",
                f"{CASES.ran} cases: SWD before one BREAK, the full walk, no walk "
                "before the load, for the GEM runner and the shell smoke",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
