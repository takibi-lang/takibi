"""GitHub issue #572: the busy pair's wait bound, made to fail on purpose.

Runs inside gdb-multiarch (`gdb -batch -x`), started by
scripts/run_kernel_affinity_gdb_qemutest.sh with
KERNEL_QEMU_AFFINITY_GDB_MODE=starve, which launches QEMU and the network
peer and passes the ports and paths in the environment.

The busy-pair verdict bounds how long either worker waits for its own CPU
while Ready: how many times one competitor may be picked there during the
wait, and how many ticks the wait may take beyond one per competitor. A
fair rotating walk keeps both at about one. What the bound is for is a
scheduler that stops covering one of the pair.

So this builds one. gdb sets the debugger-owned
`workload_busy_starve_injection_ticks` and detaches. The next-ready walks
then pass over the first worker to begin a wait in the measured window, for
that many ticks of the wait: the worker is Ready and allowed on its CPU, and
the scheduler does not pick it. The verdict must say STARVED, and the waits
line must show the reason -- a wait past the tick bound. After the injection
is spent the worker runs again and the boot finishes, so the boot's other
fixtures still report.
"""

import os
import re
import socket
import threading
import time
import sys
from pathlib import Path

import gdb

sys.path.insert(0, str(Path(__file__).resolve().parent))
from progress_timeout import ProgressTimeout  # noqa: E402
from await_timing import AwaitTiming  # noqa: E402


SERIAL_PORT = int(os.environ["AFFINITY_GDB_SERIAL_PORT"])
UART_LOG = os.environ["AFFINITY_GDB_UART_LOG"]
VERDICT = os.environ["AFFINITY_GDB_VERDICT"]
INIT_LISTENER = os.environ["AFFINITY_GDB_INIT_LISTENER"]
NETWORK_READY = os.environ["AFFINITY_GDB_NETWORK_READY"]
BOOT_TIMEOUT = float(os.environ.get("AFFINITY_GDB_BOOT_TIMEOUT", "120"))
# Report before the runner's existing gdb batch kill, even with ongoing UART.
BATCH_CEILING = float(os.environ.get("GDB_BATCH_TIMEOUT", "600")) - 10.0

LABEL = "kernel/qemu affinity-starve"
# One second at QEMU's 64 ticks per second: far past the tick bound, and
# short enough that the window still closes well inside the boot budget.
STARVE_TICKS = 64
# The verdict's tick bound, WORKLOAD_BUSY_WAIT_EXCESS_BOUND.
EXCESS_BOUND = 4
STARVED = b"workload: busy pair STARVED: a wait passed its bound\n"
BOUNDED = b"workload: busy pair waits bounded:"
WAITS = b"workload: busy pair waits a:"
# The boot reaches the busy pair the way the uart-wake lane drives it: the
# first interactive shell is sent away, and so is the payload after it.
SHELL_READY = b"interactive shell: uart blocked\n"
PAYLOAD_READY = b"concurrency: parent progressed while child uart-blocked"
PAYLOAD = b"irqtest\n"
# The starved worker ran again: the pair went on to its restart report.
PAIR_DONE = b"workload: busy pair done\n"

output = bytearray()
output_lock = threading.Lock()
capture_timeout = None


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


def observe_chunk(chunk):
    with output_lock:
        if chunk:
            capture_timeout.observe(time.monotonic())
            output.extend(chunk)
        return bytes(output)


def reader(connection: socket.socket) -> None:
    # The ash lane's two handshakes, for the same network peer. BusyBox's
    # cursor query is not answered (GitHub issue #644).
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
            text = observe_chunk(chunk)
            if (not published_init and
                    b"linux socket: listener ready port=8080\n" in text):
                open(INIT_LISTENER, "w").close()
                published_init = True
            if not published_network and b"virtio net: link ready " in text:
                open(NETWORK_READY, "w").close()
                published_network = True


def main() -> None:
    global capture_timeout
    started = time.monotonic()
    capture_timeout = ProgressTimeout(BOOT_TIMEOUT, BATCH_CEILING,
                                      started)
    timing = AwaitTiming(
        f"{UART_LOG}.await-starve.jsonl", started, BATCH_CEILING, (), (),
        label=LABEL, origin=f"GDB batch start (UART inactivity {BOOT_TIMEOUT:g}s)",
        milestones=("first shell", "UART payload ready", "starvation verdict", "pair restart"))
    try:
        run(timing)
    finally:
        timing.finish(time.monotonic())


def run(timing) -> None:
    # The UART is `wait=on`: QEMU starts when it is connected. Attaching
    # stops the machine long before init starts the busy pair.
    connection = connect(capture_timeout.deadline)
    threading.Thread(target=reader, args=(connection,), daemon=True).start()
    gdb.execute(f"target remote :{os.environ['AFFINITY_GDB_GDB_PORT']}")
    gdb.execute("set *(unsigned long *)&workload_busy_starve_injection_ticks"
                f" = {STARVE_TICKS}")
    gdb.execute("detach")
    for name, marker, answer, missing in (
            ("first shell", SHELL_READY, b"exit\n",
             "the boot never reached the interactive shell's prompt"),
            ("UART payload ready", PAYLOAD_READY, PAYLOAD, "the payload never asked for its input")):
        while True:
            with output_lock:
                if marker in output:
                    timing.record(name, True, time.monotonic())
                    break
            if capture_timeout.expired(time.monotonic()):
                verdict(False, missing)
                return
            time.sleep(0.1)
        connection.sendall(answer)
    while not capture_timeout.expired(time.monotonic()):
        with output_lock:
            text = bytes(output).replace(b"\r", b"")
        if STARVED in text:
            timing.record("starvation verdict", True, time.monotonic())
        if PAIR_DONE in text:
            timing.record("pair restart", True, time.monotonic())
        if BOUNDED in text:
            verdict(False, f"a worker passed over for {STARVE_TICKS} ticks "
                           "and the verdict still called its waits bounded")
            return
        waits = [line for line in text.split(b"\n") if line.startswith(WAITS)]
        if STARVED in text and waits and PAIR_DONE in text:
            excess = max(int(value) for value in
                         re.findall(rb" max_excess=([0-9]+)", waits[0]))
            if excess <= EXCESS_BOUND:
                verdict(False, f"STARVED, but the longest wait was {excess} "
                               "ticks past its competitors, inside the "
                               "bound: the verdict failed for another reason")
                return
            verdict(True, f"a worker passed over for {STARVE_TICKS} ticks "
                          f"waited {excess} ticks past its competitors, the "
                          "verdict said STARVED, and the boot finished")
            return
        time.sleep(0.1)
    if STARVED not in bytes(output):
        verdict(False, "the busy pair never reported a verdict")
    else:
        verdict(False, "the pair did not go on to its restart report after the starvation")


try:
    main()
except Exception as error:  # pylint: disable=broad-except
    verdict(False, f"check error: {error}")
