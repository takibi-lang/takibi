#!/usr/bin/env python3
"""Exercise kernelsh-qemu through the same PTY/miniterm path as a user."""

import os
import pty
import select
import signal
import sys
import time


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
READY_MARKER = b"interactive shell: uart blocked"
COMMAND_RESULT = b"__KERNELSH_PTY_SMOKE__"
ARTIFACT_DIR = os.path.join(REPO_ROOT, "_build", "kernelcheck-shell-qemu")
TRANSCRIPT_PATH = os.path.join(ARTIFACT_DIR, "uart-transcript.log")
START_TIMEOUT_SECONDS = 45
EXIT_TIMEOUT_SECONDS = 15


def terminate(pid):
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            exited_pid, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if exited_pid:
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


def fail(pid, transcript, message):
    terminate(pid)
    print("kernelsh-qemu PTY smoke test: FAIL: " + message, file=sys.stderr)
    if transcript:
        print("--- captured terminal transcript ---", file=sys.stderr)
        sys.stderr.buffer.write(transcript)
        if not transcript.endswith(b"\n"):
            print(file=sys.stderr)
        print("--- end transcript ---", file=sys.stderr)
    raise SystemExit(1)


def drain_terminal(terminal, transcript):
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        readable, _, _ = select.select([terminal], [], [], 0.1)
        if not readable:
            continue
        try:
            data = os.read(terminal, 4096)
        except OSError:
            return
        if not data:
            return
        transcript.extend(data)


def verify_uart_transcript(pid, terminal_transcript):
    path_bytes = TRANSCRIPT_PATH.encode()
    for marker, description in (
        ("UART transcript: ".encode() + path_bytes, "transcript start path"),
        ("UART transcript saved: ".encode() + path_bytes, "transcript exit path"),
    ):
        if marker not in terminal_transcript:
            fail(pid, terminal_transcript, f"terminal missed {description}")

    try:
        with open(TRANSCRIPT_PATH, "rb") as transcript:
            uart = transcript.read().replace(b"\r", b"")
    except OSError as error:
        fail(pid, terminal_transcript, f"UART transcript is not readable: {error}")

    required = (
        (READY_MARKER, "pre-DDB ash readiness"),
        (b"ddb: interrupt-safe UART debugger", "DDB entry"),
        (b"ddb: continuing", "DDB continue output"),
        (b"\n" + COMMAND_RESULT + b"\n", "post-resume shell output"),
    )
    for marker, description in required:
        if marker not in uart:
            fail(pid, terminal_transcript, f"UART transcript missed {description}")
    if uart.count(b"ddb: break seq=") < 2:
        fail(pid, terminal_transcript, "UART transcript missed oops command output")


def main():
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(REPO_ROOT)
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        os.environ["KERNEL_QEMU_SHELL_ARTIFACT_DIR"] = ARTIFACT_DIR
        os.environ["KERNEL_QEMU_SHELL_SERIAL_PORT"] = "18707"
        os.environ["KERNEL_QEMU_SHELL_HTTP_PORT"] = "18708"
        os.environ["KERNEL_QEMU_SHELL_SKIP_NETWORK"] = "1"
        os.execvp("make", ["make", "-j1", "kernelsh-qemu"])

    transcript = bytearray()
    break_sent = False
    ddb_prompt_count = 0
    command_sent = False
    deadline = time.monotonic() + START_TIMEOUT_SECONDS

    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.25)
            if readable:
                try:
                    data = os.read(terminal, 4096)
                except OSError:
                    data = b""
                if data:
                    transcript.extend(data)
                    normalized = bytes(transcript).replace(b"\r", b"")
                    if not break_sent and READY_MARKER in normalized and b"/ # " in normalized:
                        os.write(terminal, b"\x14b")  # Ctrl-T, then lowercase b
                        break_sent = True
                    prompts = normalized.count(b"ddb> ")
                    while ddb_prompt_count < prompts:
                        if ddb_prompt_count == 0:
                            os.write(terminal, b"oops\n")
                        elif ddb_prompt_count == 1:
                            os.write(terminal, b"continue\n")
                        ddb_prompt_count += 1
                    if (not command_sent and b"ddb: continuing\n" in normalized):
                        os.write(terminal, b"x=; echo " + COMMAND_RESULT + b"\n")
                        command_sent = True
                    if command_sent and b"\n" + COMMAND_RESULT + b"\n" in normalized:
                        os.write(terminal, b"\x1d")
                        break

            exited_pid, status = os.waitpid(pid, os.WNOHANG)
            if exited_pid:
                fail(pid, transcript, "make kernelsh-qemu exited before ash responded")
        else:
            fail(pid, transcript, "timed out waiting for ash command response")

        deadline = time.monotonic() + EXIT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            exited_pid, status = os.waitpid(pid, os.WNOHANG)
            if exited_pid:
                if status == 0:
                    drain_terminal(terminal, transcript)
                    verify_uart_transcript(pid, transcript)
                    print("kernelsh-qemu PTY smoke test: PASS")
                    return
                fail(pid, transcript, "make kernelsh-qemu exited unsuccessfully")
            time.sleep(0.1)
        fail(pid, transcript, "timed out waiting for Ctrl-] cleanup")
    finally:
        os.close(terminal)


if __name__ == "__main__":
    main()
