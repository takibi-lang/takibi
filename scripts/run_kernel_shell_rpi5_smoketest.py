#!/usr/bin/env python3
"""Exercise the existing RPi5 interactive shell launcher and HTTP profile."""

import hashlib
import json
import os
from pathlib import Path
import pty
import signal
import sys
import time
import urllib.request

from await_timing import AwaitTiming
from run_kernel_churn import Session, FailureMarker, has_prompt, terminate

ROOT = Path(__file__).resolve().parent.parent
LISTENER = b"persistent server: listener ready port=8080"
SHELL = b"interactive shell: uart blocked"
PS_DONE = b"__RPI5_SHELL_HTTP_PS__"
# BusyBox rewrites the document-root argument to '.' after changing directory.
# Count its command prefix, as the QEMU shell smoke does, including workers.
HTTPD = b"/bin/httpd -f -p 8080 -h"
BODY_MARKER = b"<h1>Takibi Kernel</h1>"
BOOT_SECONDS = 180
COMMAND_SECONDS = 20
EXIT_SECONDS = 15


def shell_ready(text):
    return LISTENER in text and SHELL in text and has_prompt(text)


def process_snapshot(text):
    marker = b"\n" + PS_DONE + b"\n"
    if marker not in text:
        return None
    snapshot, following = text.split(marker, 1)
    if not has_prompt(b"\n" + following):
        return None
    processes = [line for line in snapshot.splitlines() if HTTPD in line]
    if len(processes) != 1:
        raise RuntimeError(f"ps showed {len(processes)} HTTPd processes; expected one listener")
    return snapshot


def fetch_index(url, directory, number):
    # The board is on a direct local link, independent of host proxy settings.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=15) as response:
        body = response.read(65537)
        (directory / f"http-{number}.body").write_bytes(body)
        (directory / f"http-{number}.headers").write_text(str(response.headers))
        if response.status != 200:
            raise RuntimeError(f"HTTP request {number} returned {response.status}")
        if response.headers.get_content_type() != "text/html":
            raise RuntimeError(f"HTTP request {number} did not return text/html")
        if len(body) > 65536 or BODY_MARKER not in body:
            raise RuntimeError(f"HTTP request {number} missed the bounded index body")


def await_console(session, directory, phase, seconds, predicate, watch_from=None):
    started = time.monotonic()
    timing = AwaitTiming(str(directory / f"await-{phase}.jsonl"), started,
                         seconds, [], [], label="kernel/rpi5 shell smoke",
                         origin=f"{phase} start", milestones=(phase,))
    try:
        answer = session.wait_for(predicate, seconds, watch_from=watch_from)
        if isinstance(answer, FailureMarker):
            raise RuntimeError(f"kernel failure marker {answer.marker!r}")
        if answer is None:
            raise RuntimeError(f"console did not complete {phase} within {seconds}s")
        timing.record(phase, True, time.monotonic())
        return answer
    finally:
        timing.finish(time.monotonic())


def run(session, directory, url, note_phase=lambda _phase: None):
    phase = "shell-and-listener"
    note_phase(phase)
    print(f"[kernel/rpi5 shell smoke] {phase}", flush=True)
    await_console(session, directory, phase, BOOT_SECONDS, shell_ready)
    for number in (1, 2):
        phase = f"http-{number}"
        note_phase(phase)
        print(f"[kernel/rpi5 shell smoke] {phase}", flush=True)
        fetch_index(url, directory, number)
        phase = f"processes-after-http-{number}"
        note_phase(phase)
        print(f"[kernel/rpi5 shell smoke] {phase}", flush=True)
        start = len(session.normalized())
        session.send(b"ps; echo " + PS_DONE + b"\n")
        snapshot = await_console(session, directory, phase, COMMAND_SECONDS,
                                 lambda text: process_snapshot(text[start:]), start)
        (directory / f"ps-{number}.log").write_bytes(snapshot)
    return "console-exit"


def main():
    default_directory = Path(os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT", ROOT / "_build")) / "kernel-shell-smoke-rpi5"
    directory = Path(os.environ.get("KERNEL_RPI5_SHELL_SMOKE_ARTIFACT_DIR", default_directory)).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    # The shell launcher truncates its own UART capture. Remove only this
    # driver's previous results so a failed attempt cannot retain old verdicts.
    for pattern in ("http-*", "ps-*.log", "await-*.jsonl", "result.json",
                    "uart-transcript.log", "network-peer.log", "terminal.log"):
        for path in directory.glob(pattern):
            path.unlink()
    elf = ROOT / "kernel/build/rpi5/kernel-shell.elf"
    digest = hashlib.sha256(elf.read_bytes()).hexdigest()
    subnet = os.environ.get("ETH_TEST_SUBNET", "192.168.20")
    url = f"http://{subnet}.2:8080/"
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.environ.pop("KERNEL_SHELL_TRANSCRIPT", None)
        os.environ["KERNEL_RPI5_SHELL_ARTIFACT_DIR"] = str(directory)
        os.environ["KERNEL_RPI5_SHELL_NETWORK_PEER"] = "1"
        os.execvp("bash", ["bash", "scripts/run_kernel_shell_rpi5.sh"])
    session = Session(pid, terminal)
    started = time.monotonic()
    result = {"status": "FAIL", "phase": "shell-and-listener", "url": url,
              "elf": str(elf), "elf_sha256": digest}

    def stop(signum, _frame):
        raise RuntimeError(f"stopped by signal {signum}")

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        # Save the current phase even when a callback raises or a wait expires.
        def note_phase(phase):
            result["phase"] = phase
        run(session, directory, url, note_phase)
        result["phase"] = "console-exit"
        session.send(b"\x1d")
        deadline = time.monotonic() + EXIT_SECONDS
        while time.monotonic() < deadline:
            exited, status = os.waitpid(pid, os.WNOHANG)
            if exited:
                if status != 0:
                    raise RuntimeError(f"shell launcher exited with wait status {status}")
                result["status"] = "PASS"
                print("PASS kernel/rpi5 shell smoke: two HTTP responses and one listener after each", flush=True)
                return 0
            time.sleep(0.1)
        raise RuntimeError("Ctrl-] did not exit the shell launcher within 15s")
    except (OSError, RuntimeError) as error:
        result["error"] = str(error)
        print(f"FAIL kernel/rpi5 shell smoke at {result['phase']}: {error}; artifacts: {directory}", file=sys.stderr)
        return 1
    finally:
        terminate(pid)
        os.close(terminal)
        (directory / "terminal.log").write_bytes(session.transcript)
        result["elapsed_seconds"] = time.monotonic() - started
        (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
