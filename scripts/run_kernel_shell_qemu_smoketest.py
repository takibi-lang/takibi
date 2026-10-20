#!/usr/bin/env python3
"""Exercise kernelsh-qemu through the same PTY/miniterm path as a user."""

import os
import pty
import re
import select
import signal
import subprocess
import shutil
import sys
import time
import urllib.request

from lease_wait import lease_pending, timed_out_waiting
from qemu_vcpu_lease import lease, shell_vcpus
from progress_timeout import ProgressTimeout
from await_timing import AwaitTiming
from typed_marker import typed_marker


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
HTTPD_REAP_BEGIN = b"__KERNELSH_HTTPD_REAP_BEGIN__"
HTTPD_REAP_END = b"__KERNELSH_HTTPD_REAP_END__"
HTTPD_PROCESS = b"/bin/httpd -f -p 8080 -h"


COMMAND_LINE = b"x=; echo " + typed_marker(COMMAND_RESULT) + b"\n"
HTTPD_REAP_LINE = (b"echo " + typed_marker(HTTPD_REAP_BEGIN) + b"; ps; echo " +
                   typed_marker(HTTPD_REAP_END) + b"\n")


def httpd_reap_count(normalized):
    """Count httpd lines that ps printed between the reap markers.

    Returns None until both marker lines arrived.  Only echo's output lines
    anchor the window, so neither the echoed command line nor a workload line
    interleaved with it can open or close the window (#856).
    """
    begin = b"\n" + HTTPD_REAP_BEGIN + b"\n"
    end = b"\n" + HTTPD_REAP_END + b"\n"
    start = normalized.find(begin)
    if start < 0:
        return None
    stop = normalized.find(end, start + len(begin) - 1)
    if stop < 0:
        return None
    window = normalized[start + len(begin):stop]
    return sum(1 for line in window.splitlines() if HTTPD_PROCESS in line)
ARTIFACT_DIR = os.path.join(REPO_ROOT, "_build", "kernelcheck-shell-qemu")
TRANSCRIPT_PATH = os.path.join(ARTIFACT_DIR, "uart-transcript.log")
START_TIMEOUT_SECONDS = 45
START_CEILING_SECONDS = float(os.environ.get("KERNEL_QEMU_CEILING", "270"))
EXIT_TIMEOUT_SECONDS = 15
# GitHub issue #862: the fourth boot sends PID 1 SIGQUIT. BusyBox init then
# exec's inittab.shell's ::restart: image (/etc/restart.sh) in place of
# itself -- PID 1's own exec -- and that image exits, which is PID 1's exit
# and the kernel's fail-stop (kernel_syscall_init_exit).
INIT_EXIT = "init-exit"
INIT_RESTART_MARKER = b"\ninit restart: pid=1\n"
INIT_EXIT_STOP_MARKER = b"\ninit: PID 1 exited unexpectedly status=7\n"


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


def verify_uart_transcript(pid, terminal_transcript, stop_marker, command):
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
        (stop_marker, "PID 1 exit fail-stop" if command == INIT_EXIT
         else "all-core system stop"),
        (LISTENER_MARKER, "persistent HTTPd listener readiness"),
        (b"ddb: interrupt-safe UART debugger", "DDB entry"),
        (b"ddb: continuing", "DDB continue output"),
        (b"\n" + COMMAND_RESULT + b"\n", "post-resume shell output"),
    )
    if command == INIT_EXIT:
        required += ((INIT_RESTART_MARKER, "PID 1 running the exec'd image"),)
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


def run_one(command, http_offset):
    name = "restart" if command == "reboot" else command
    if command == INIT_EXIT:
        stop_marker = INIT_EXIT_STOP_MARKER
        stop_line = b"x=; kill -QUIT 1\n"
    else:
        stop_marker = f"\nsystem stop: {name} (all cores parked)\n".encode("ascii")
        stop_line = f"x=; /bin/busybox {command} -f\n".encode("ascii")
    startup_path = os.path.join(ARTIFACT_DIR, f"await-{command}.jsonl")
    exit_path = os.path.join(ARTIFACT_DIR, f"await-{command}-exit.jsonl")
    try:
        os.makedirs(ARTIFACT_DIR, exist_ok=True)
        if os.path.exists(exit_path):
            os.unlink(exit_path)
    except OSError as error:
        print(f"RECORDED kernel/pty await artifact unavailable: {error}", flush=True)
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(REPO_ROOT)
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        os.environ["KERNEL_QEMU_SHELL_ARTIFACT_DIR"] = ARTIFACT_DIR
        os.environ.pop("KERNEL_QEMU_SHELL_SKIP_NETWORK", None)
        # The previous HTTP listener can leave TIME_WAIT sockets. TCP and
        # UDP have separate port spaces, so reuse the shell network numbers
        # for the second and third HTTP listeners within the same lane block.
        http_base = int(os.environ.get("KERNEL_QEMU_SHELL_HTTP_PORT", "18080"))
        os.environ["KERNEL_QEMU_SHELL_HTTP_PORT"] = str(http_base + http_offset)
        os.execvp("bash", ["bash", "scripts/run_kernel_shell_qemu.sh"])

    transcript = bytearray()
    stop_sent = False
    break_sent = False
    ddb_prompt_count = 0
    command_sent = False
    reap_check_sent = False
    reap_check_done = False
    http_checked = False
    started = time.monotonic()
    startup = ProgressTimeout(START_TIMEOUT_SECONDS, START_CEILING_SECONDS, started)
    startup_timing = AwaitTiming(
        startup_path, started, START_CEILING_SECONDS, [], [],
        label=f"kernel/pty {command}",
        origin=f"startup ceiling (UART inactivity limit {START_TIMEOUT_SECONDS:g}s)",
        milestones=("shell ready", "command response", "all cores parked"))
    exit_timing = None

    try:
        while not startup.expired(time.monotonic()):
            readable, _, _ = select.select([terminal], [], [], 0.25)
            if lease_pending(transcript):
                # The runner is still waiting for its vCPUs (#719): QEMU has
                # not started, so neither has the boot this times.
                startup = ProgressTimeout(START_TIMEOUT_SECONDS,
                                          START_CEILING_SECONDS, time.monotonic())
            if readable:
                try:
                    data = os.read(terminal, 4096)
                except OSError:
                    data = b""
                if data:
                    arrived_at = time.monotonic()
                    startup.observe(arrived_at)
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
                    if ready:
                        startup_timing.record("shell ready", True, arrived_at)
                    if (not reap_check_sent and http_checked and ready and
                            b" # " in normalized):
                        os.write(terminal, HTTPD_REAP_LINE)
                        reap_check_sent = True
                    reap_marker = b"\n" + HTTPD_REAP_END + b"\n"
                    httpd_count = httpd_reap_count(normalized) if reap_check_sent else None
                    if not reap_check_done and httpd_count is not None:
                        if httpd_count != 1:
                            fail(
                                pid, transcript,
                                "completed HTTP requests left child httpd zombies "
                                f"(ps showed {httpd_count} httpd processes)",
                            )
                        reap_check_done = True
                    after_reap_marker = b""
                    if reap_marker in normalized:
                        after_reap_marker = normalized.split(reap_marker, 1)[1]
                    if (not break_sent and reap_check_done and
                            b" # " in after_reap_marker):
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
                        os.write(terminal, COMMAND_LINE)
                        command_sent = True
                    if (command_sent and not stop_sent and
                            b"\n" + COMMAND_RESULT + b"\n" in normalized):
                        startup_timing.record("command response", True, arrived_at)
                        os.write(terminal, stop_line)
                        stop_sent = True
                    if stop_sent and stop_marker in normalized:
                        startup_timing.record("all cores parked", True, arrived_at)
                        os.write(terminal, b"\x1d")
                        break

            exited_pid, status = os.waitpid(pid, os.WNOHANG)
            if exited_pid:
                fail(pid, transcript, "make kernelsh-qemu exited before ash responded")
        else:
            fail(pid, transcript, timed_out_waiting(transcript) or
                 "timed out waiting for ash command response and system stop")

        startup_timing.finish(time.monotonic())
        exit_started = time.monotonic()
        deadline = exit_started + EXIT_TIMEOUT_SECONDS
        exit_timing = AwaitTiming(exit_path, exit_started, EXIT_TIMEOUT_SECONDS, [], [],
                                 label=f"kernel/pty {command}", origin="Ctrl-] cleanup start",
                                 milestones=("child process exit",))
        while time.monotonic() < deadline:
            exited_pid, status = os.waitpid(pid, os.WNOHANG)
            if exited_pid:
                exit_timing.record("child process exit", True, time.monotonic())
                if status == 0:
                    drain_terminal(terminal, transcript)
                    verify_uart_transcript(pid, transcript, stop_marker, command)
                    shutil.copyfile(TRANSCRIPT_PATH,
                                    os.path.join(ARTIFACT_DIR, f"uart-{command}.log"))
                    outcome = ("PID 1 exec'd and exited, kernel stopped"
                               if command == INIT_EXIT else "all cores parked")
                    print(f"kernelsh-qemu PTY smoke test: PASS ({name}, {outcome})")
                    return
                fail(pid, transcript, "make kernelsh-qemu exited unsuccessfully")
            time.sleep(0.1)
        fail(pid, transcript, "timed out waiting for Ctrl-] cleanup")
    finally:
        startup_timing.finish(time.monotonic())
        if exit_timing is not None:
            exit_timing.finish(time.monotonic())
        os.close(terminal)


def main():
    # Build before the PTY deadline: a clean compiler/build-check pass is
    # host preparation, not guest boot or shell response time. Run the same
    # console recipe as kernelsh-qemu after its prerequisites have passed.
    subprocess.run(["make", "-j1", "kernelbuild-qemu",
                    "kernel/build/user/ext2-shell.img"],
                   cwd=REPO_ROOT, check=True)
    # GitHub issue #719: hold the runner's vCPUs before the PTY deadline; the
    # runner finds them on its ancestor. lease() re-executes this script, and
    # the build above is then a no-op.
    lease(shell_vcpus())
    for http_offset, command in enumerate(("halt", "poweroff", "reboot",
                                           INIT_EXIT)):
        run_one(command, http_offset)


if __name__ == "__main__":
    main()
