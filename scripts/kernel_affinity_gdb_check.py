"""Observe affinity-preserving syscall dispatch on CPU 1 (#1330).

The existing affinity GDB lane watches a parent-progress syscall enter
on CPU 1, reach its real handler there, and then dispatch getcpu on CPU 1.
No frame is read through a potentially different address-space root (#585).
Explicit affinity migrations remain covered by /bin/affinity's other phases.
"""

import os
import signal
import socket
import threading
import time

import gdb

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdb_progress import STALLED, continue_by_ticks  # noqa: E402
from progress_timeout import ProgressTimeout  # noqa: E402
from await_timing import AwaitTiming  # noqa: E402


SERIAL_PORT = int(os.environ["AFFINITY_GDB_SERIAL_PORT"])
GDB_PORT = int(os.environ["AFFINITY_GDB_GDB_PORT"])
UART_LOG = os.environ["AFFINITY_GDB_UART_LOG"]
VERDICT = os.environ["AFFINITY_GDB_VERDICT"]
INIT_LISTENER = os.environ["AFFINITY_GDB_INIT_LISTENER"]
NETWORK_READY = os.environ["AFFINITY_GDB_NETWORK_READY"]
BOOT_TIMEOUT = float(os.environ.get("AFFINITY_GDB_BOOT_TIMEOUT", "120"))
BATCH_DEADLINE = time.monotonic() + float(os.environ.get("GDB_BATCH_TIMEOUT", "600")) - 10.0
STEP_TIMEOUT = 60.0
# GitHub issue #867: a gdb step is bounded by the ticks both vCPUs take, not
# by host seconds (scripts/gdb_progress.py). About a minute of the guest's own
# time at 64 Hz, the guest-time equivalent of the former STEP_TIMEOUT.
STEP_TICKS = 64 * 60

LABEL = "kernel/qemu affinity-gdb"
SHELL_READY = b"interactive shell: uart blocked\n"
COMMAND = b"/bin/affinity\n"
PINNED = b"affinity: pinned to cpu 1, where parent_progress answered without rerouting"
# The entry addresses themselves, where x0 and x1 are still the call's
# arguments. With a debug image (KERNEL_QEMU_AFFINITY_GDB_ELF), a function
# breakpoint would land after the prologue, where they may be gone.
HANDLER = "*kernel_process_uart_record_parent_progress"
DISPATCH = "*kernel_syscall_dispatch"
DISPATCHED_SYSCALL = 452
GETCPU_SYSCALL = 168
# QEMU's gdbstub numbers vCPUs from 1: thread 1 is CPU0, thread 2 is CPU1.
CPU0_THREAD = 1
CPU1_THREAD = 2

output = bytearray()
output_lock = threading.Lock()


def verdict(ok: bool, message: str) -> None:
    line = f"{'PASS' if ok else 'FAIL'} {LABEL}: {message}"
    print(line, flush=True)
    with open(VERDICT, "w", encoding="ascii") as handle:
        handle.write(line + "\n")


def connect(deadline: float) -> socket.socket:
    last = None
    while time.monotonic() < deadline:
        try:
            return socket.create_connection(("127.0.0.1", SERIAL_PORT), timeout=1)
        except OSError as error:
            last = error
            time.sleep(0.1)
    raise RuntimeError(f"could not reach the UART on port {SERIAL_PORT}: {last}")


def reader(connection: socket.socket) -> None:
    # The same two handshakes the ash lane's driver publishes, for the same
    # network peer: without them the boot's network fixtures wait it out.
    published_init = False
    published_network = False
    connection.settimeout(0.2)
    with open(UART_LOG, "wb") as log:
        while True:
            try:
                chunk = connection.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                return
            log.write(chunk)
            log.flush()
            with output_lock:
                output.extend(chunk)
                seen = bytes(output)
            if (not published_init and
                    b"linux socket: listener ready port=8080\n" in seen):
                open(INIT_LISTENER, "w").close()
                published_init = True
            if not published_network and b"virtio net: link ready " in seen:
                open(NETWORK_READY, "w").close()
                published_network = True


def seen(predicate, timeout: float, *, phase, boot=False) -> bool:
    started = time.monotonic()
    ceiling = max(0.0, BATCH_DEADLINE - started) if boot else timeout
    timer = ProgressTimeout(timeout, ceiling, started)
    timing = AwaitTiming(
        f"{UART_LOG}.await-{phase}.jsonl", started, ceiling, (), (),
        label=LABEL, origin=(f"remaining GDB batch ceiling (UART inactivity {timeout:g}s)"
                             if boot else "command response start"), milestones=(phase,))
    with output_lock:
        previous_size = len(output)
    try:
        while not timer.expired(time.monotonic()):
            with output_lock:
                size, text = len(output), bytes(output)
            if boot and size > previous_size:
                timer.observe(time.monotonic())
                previous_size = size
            if predicate(text):
                timing.record(phase, True, time.monotonic())
                return True
            time.sleep(0.1)
        return False
    finally:
        timing.finish(time.monotonic())


def continue_bounded(breakpoint: gdb.Breakpoint) -> str:
    """Resume both vCPUs until `breakpoint` is hit, bounded by their ticks.

    Returns DONE, QUIET (both vCPUs took STEP_TICKS ticks and it was never
    hit: a finding) or STALLED (a slice in which a vCPU took no tick, or the
    host-time cap: inconclusive, never a negative verdict) (#865, #867).
    """
    threads = (CPU0_THREAD, CPU1_THREAD)
    outcome, _ = continue_by_ticks(lambda: breakpoint.hit_count > 0,
                                   threads, STEP_TICKS)
    return outcome


def stalled(step: str) -> str:
    """The inconclusive verdict for a step the guest was not given time for:
    distinct from every negative one, which needs QUIET (#867)."""
    return (f"inconclusive at the {step} step: the guest stalled (a slice in "
            "which CPU0 or CPU1 took no scheduler tick, or the host-time cap) "
            f"before its breakpoint was hit. {where()}. "
            f"UART tail: {uart_tail()!r}")


def register(name: str) -> int:
    return int(gdb.parse_and_eval(f"${name}")) & 0xFFFFFFFFFFFFFFFF


def uart_tail() -> str:
    with output_lock:
        return bytes(output[-200:]).decode("ascii", errors="replace")


def where() -> str:
    """Name each vCPU's PC, so a failed step says what the machine was doing."""
    places = []
    for thread in (CPU0_THREAD, CPU1_THREAD):
        try:
            gdb.execute(f"thread {thread}", to_string=True)
            pc = register("pc")
            symbol = gdb.execute(f"info symbol {pc:#x}", to_string=True).strip()
            places.append(f"thread {thread} at {pc:#x} ({symbol})")
        except gdb.error as error:
            places.append(f"thread {thread} unreadable ({error})")
    return "; ".join(places)


def run() -> None:
    connection = connect(time.monotonic() + 30)
    threading.Thread(target=reader, args=(connection,), daemon=True).start()
    if not seen(lambda text: SHELL_READY in text, BOOT_TIMEOUT, phase="first-shell", boot=True):
        verdict(False, "the boot never reached the interactive shell's prompt")
        return

    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    # The function entry preserves the ABI arguments (#585).
    asked = gdb.Breakpoint(DISPATCH)
    asked.condition = (f"$x1 == {DISPATCHED_SYSCALL} && "
                       f"$_thread == {CPU1_THREAD}")
    connection.sendall(COMMAND)
    outcome = continue_bounded(asked)
    if outcome == STALLED:
        verdict(False, stalled("ask"))
        gdb.execute("detach")
        return
    if asked.hit_count == 0:
        verdict(False, f"/bin/affinity never asked parent_progress from CPU 1. {where()}")
        gdb.execute("detach")
        return
    asked.delete()

    handler = gdb.Breakpoint(HANDLER)
    handler.condition = f"$_thread == {CPU1_THREAD}"
    outcome = continue_bounded(handler)
    if outcome == STALLED:
        verdict(False, stalled("handler"))
        gdb.execute("detach")
        return
    if handler.hit_count != 1:
        verdict(False, f"parent_progress handler did not run on CPU 1. {where()}")
        gdb.execute("detach")
        return
    handler.delete()

    resumed = gdb.Breakpoint(DISPATCH)
    resumed.condition = f"$x1 == {GETCPU_SYSCALL} && $_thread == {CPU1_THREAD}"
    outcome = continue_bounded(resumed)
    if outcome == STALLED:
        verdict(False, stalled("return"))
        gdb.execute("detach")
        return
    if resumed.hit_count != 1:
        verdict(False, f"the caller never dispatched getcpu again on CPU 1. {where()}")
        gdb.execute("detach")
        return
    resumed.delete()
    gdb.execute("detach")
    if not seen(lambda text: PINNED in text, STEP_TIMEOUT, phase="affinity-answer"):
        verdict(False, "/bin/affinity did not confirm the unchanged result and CPU")
        return
    verdict(True, "parent_progress dispatched and handled on CPU 1; the caller "
            "then dispatched getcpu there and checked its EINVAL result and affinity")


try:
    run()
except Exception as error:  # noqa: BLE001 -- the verdict file is the interface
    verdict(False, f"the gdb check stopped: {error}")
