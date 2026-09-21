#!/usr/bin/env python3
"""Exercise kernelsh-qemu through the same PTY/miniterm path as a user."""

import os
import pty
import re
import select
import signal
import sys
import time
import urllib.request


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
READY_MARKERS = (
    b"persistent shell: uart blocked",
    b"interactive shell: uart blocked",
)
LISTENER_MARKER = b"persistent server: listener ready port=8080"
HTTP_URL_PATTERN = re.compile(
    b"open in a host browser" + bytes((58, 32)) +
    rb"(http://127\.0\.0\.1:[0-9]+/)"
)
HTTP_BODY_MARKER = b"<h1>Takibi Kernel</h1>"
COMMAND_RESULT = b"__KERNELSH_PTY_SMOKE__"
HTTPD_REAP_RESULT = b"__KERNELSH_HTTPD_REAP__"
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
        (LISTENER_MARKER, "persistent HTTPd listener readiness"),
        (b"ddb: interrupt-safe UART debugger", "DDB entry"),
        (b"ddb: continuing", "DDB continue output"),
        (b"\n" + COMMAND_RESULT + b"\n", "post-resume shell output"),
    )
    for marker, description in required:
        if marker not in uart:
            fail(pid, terminal_transcript, f"UART transcript missed {description}")
    if uart.count(b"ddb: break seq=") < 2:
        fail(pid, terminal_transcript, "UART transcript missed oops command output")


def verify_http(url):
    for request_number in range(1, 3):
        with urllib.request.urlopen(url, timeout=5) as response:
            body = response.read()
            if response.status != 200:
                raise RuntimeError(
                    f"HTTP request {request_number} returned {response.status}"
                )
            if HTTP_BODY_MARKER not in body:
                raise RuntimeError(
                    f"HTTP request {request_number} missed the index marker"
                )


def main():
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(REPO_ROOT)
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        os.environ["KERNEL_QEMU_SHELL_ARTIFACT_DIR"] = ARTIFACT_DIR
        os.environ.pop("KERNEL_QEMU_SHELL_SKIP_NETWORK", None)
        os.execvp("make", ["make", "-j1", "kernelsh-qemu"])

    transcript = bytearray()
    break_sent = False
    ddb_prompt_count = 0
    command_sent = False
    reap_check_sent = False
    reap_check_done = False
    http_checked = False
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
                    url_match = HTTP_URL_PATTERN.search(normalized)
                    if not http_checked and url_match is not None:
                        try:
                            verify_http(url_match.group(1).decode("ascii"))
                        except (OSError, RuntimeError) as error:
                            fail(pid, transcript, f"interactive HTTP check failed: {error}")
                        http_checked = True
                    ready = any(marker in normalized for marker in READY_MARKERS)
                    if (not reap_check_sent and http_checked and ready and
                            b"/ # " in normalized):
                        os.write(terminal, b"ps; echo " + HTTPD_REAP_RESULT + b"\n")
                        reap_check_sent = True
                    reap_marker = b"\n" + HTTPD_REAP_RESULT + b"\n"
                    if reap_check_sent and not reap_check_done and reap_marker in normalized:
                        before_marker = normalized.split(reap_marker, 1)[0]
                        process_lines = [
                            line for line in before_marker.splitlines()
                            if b"/bin/httpd -f -p 8080 -h" in line
                        ]
                        if len(process_lines) != 1:
                            fail(
                                pid, transcript,
                                "completed HTTP requests left child httpd zombies "
                                f"(ps showed {len(process_lines)} httpd processes)",
                            )
                        reap_check_done = True
                    after_reap_marker = b""
                    if reap_marker in normalized:
                        after_reap_marker = normalized.split(reap_marker, 1)[1]
                    if (not break_sent and reap_check_done and
                            b"/ # " in after_reap_marker):
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
