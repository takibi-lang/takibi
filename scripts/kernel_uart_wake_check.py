"""GitHub issue #546: a byte that arrives while a terminal read is on its way
to sleep must still reach the reader.

Runs inside gdb-multiarch (`gdb -batch -x`), started by
scripts/run_kernel_uart_wake_qemutest.sh, which launches QEMU and the
network peer and passes the ports and paths in the environment.

The failure this pins down was seen twice in qemu-debug lanes: the shell
blocked on uart-rx beside a byte that had arrived, and nothing woke it. A
terminal read finds the ring empty, unmasks interrupts, and only then
blocks. A byte that arrives in between finds no Blocked reader, goes into
the ring, and raises nothing further. That window is a few hundred
instructions wide, so rerunning a lane until it happens is not a test.

So this opens the window on purpose. syscall_test_evidence_record_read_uart_wait
is called on exactly that path, after the interrupts are unmasked and before
the read blocks. A breakpoint there stops the guest inside the window. While
it is stopped, one byte is sent to the UART, and QEMU's main loop puts it in
the PL011 FIFO and raises the interrupt. Continuing takes that interrupt
inside the window, every time. The shell is sent a command one byte per
stop. After each byte, the shell has to come back to the breakpoint, which
means it read that byte and went to read the next one. Then the command's
output has to appear.

A kernel with the window open stops at the second byte: it goes to sleep
with the byte in the ring and never reads again.

UART_WAKE_MODE=peer runs the same window across CPUs (GitHub issue #547).
The persistent shell starts /bin/peer-tty, which the kernel admits only on
the secondary CPU, and waits for it, so it is the terminal's only reader.
gdb holds CPU1 at kernel_process_block_uart: the reader has taken its last
lockless look at the ring, and has not yet taken the lock that publishes it
Blocked. With CPU1 held there, one byte is sent. Only CPU0 is run, until its
RX interrupt is inside kernel_uart_rx_push, having found no Blocked reader.
Then both run. The reader must come back to the window for the next byte.
Without the look under that lock, it publishes Blocked beside the byte and
sleeps. A local interrupt mask cannot close this window, because the
interrupt is taken on the other CPU.

The same peer suite exercises GitHub issue #829 with /bin/peer-net-wake, on
the real Blocked/NetRx scheduler path. The waiter blocks on CPU1 and is queued
on CPU1's own tick-wake list in the critical section that publishes it Blocked
(which is what closed #587's check-then-block race: no other core's walk can
look between the two). gdb then freezes CPU0 and runs CPU1 alone; CPU1's own
tick must wake the waiter. A generated control kernel whose secondary tick
wakes nothing of its own must leave it asleep. The pair runs sequentially on
the existing lane.
"""

import json
import os
import signal
import socket
import threading
import time

import gdb

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdb_interrupt import interrupt_after  # noqa: E402
from progress_timeout import ProgressTimeout  # noqa: E402
from await_timing import AwaitTiming  # noqa: E402


SERIAL_PORT = int(os.environ["UART_WAKE_SERIAL_PORT"])
GDB_PORT = int(os.environ["UART_WAKE_GDB_PORT"])
UART_LOG = os.environ["UART_WAKE_UART_LOG"]
VERDICT = os.environ["UART_WAKE_VERDICT"]
INIT_LISTENER = os.environ["UART_WAKE_INIT_LISTENER"]
NETWORK_READY = os.environ["UART_WAKE_NETWORK_READY"]
BOOT_TIMEOUT = float(os.environ.get("UART_WAKE_BOOT_TIMEOUT", "120"))
BATCH_DEADLINE = time.monotonic() + float(
    os.environ.get("GDB_BATCH_TIMEOUT", str(BOOT_TIMEOUT * 6))) - 10.0
STEP_TIMEOUT = 10.0

WINDOW = "syscall_test_evidence_record_read_uart_wait"
COMMAND = b"echo uart-wake-ok\n"
ANSWER = "uart-wake-ok"
SHELL_READY = b"interactive shell: uart blocked\n"
# The same marker and answer scripts/run_kernel_uart_driver.py uses.
PAYLOAD_READY = b"concurrency: parent progressed while child uart-blocked"
PAYLOAD = b"irqtest\n"
PERSISTENT_READY = b"persistent shell: uart blocked\n"
SPINNER = b"while :; do :; done &\n"
PEER_SPINNER = b"/bin/peer-spin &\n"
PEER_SPINNER_READY = b"peer spin: pinned to cpu 1\n"

MODE = os.environ.get("UART_WAKE_MODE", "shell")
LABEL = ("kernel/qemu peer-uart-and-net-wake-control"
         if MODE == "peer-net-control" else
         "kernel/qemu peer-uart-and-net-wake" if MODE == "peer" else
         "kernel/qemu uart-wake")
PEER_COMMAND = b"/bin/peer-tty\n"
PEER_CONSOLE_DONE = b"peer user console: record=17/17 "
BUSY_PAIR_DONE = b"workload: busy pair done\n"
PEER_READING = b"workload: peer tty reading the terminal on the secondary cpu\n"
PEER_LINE = b"peer-tty-line-ok\n"
PEER_VERDICT = b"workload: peer tty read its 17-byte line"
PEER_NET_WAKE_COMMAND = b"/bin/peer-net-wake\n"
PEER_NET_WAKE_READY = b"peer NetRx fixture: pinned to cpu 1\n"
PEER_NET_WAKE_VERDICT = b"workload: peer NetRx waiter resumed on cpu 1"
PEER_WINDOW = "kernel_process_block_uart"
RING_PUSH = "kernel_uart_rx_push"
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
            # BusyBox's cursor query (ESC[6n) is not answered: a late
            # reply lands in the next command (GitHub issue #644).
            if (not published_init and
                    b"linux socket: listener ready port=8080\n" in seen):
                open(INIT_LISTENER, "w").close()
                published_init = True
            if not published_network and b"virtio net: link ready " in seen:
                open(NETWORK_READY, "w").close()
                published_network = True


def seen(predicate, timeout: float, *, boot_phase=None, response_phase=None) -> bool:
    started = time.monotonic()
    remaining = max(0.0, BATCH_DEADLINE - started)
    timer = ProgressTimeout(timeout, remaining if boot_phase else timeout, started)
    timing = None
    phase = boot_phase or response_phase
    if phase:
        timing = AwaitTiming(
            f"{UART_LOG}.await-{phase}.jsonl", started,
            remaining if boot_phase else timeout, (), (), label=LABEL,
            origin=(f"remaining GDB batch ceiling (UART inactivity {timeout:g}s)"
                    if boot_phase else "command response start"), milestones=(phase,))
    with output_lock:
        previous_size = len(output)
    try:
        while not timer.expired(time.monotonic()):
            with output_lock:
                size = len(output)
                text = bytes(output).replace(b"\r\n", b"\n")
            if boot_phase and size > previous_size:
                timer.observe(time.monotonic())
                previous_size = size
            if predicate(text):
                if timing:
                    timing.record(phase, True, time.monotonic())
                return True
            time.sleep(0.1)
        return False
    finally:
        if timing:
            timing.finish(time.monotonic())


def answered(text: bytes) -> bool:
    lines = text.decode("ascii", errors="replace").replace("\r", "").splitlines()
    return any(line.removeprefix("/ # ").removeprefix(" # ") == ANSWER for line in lines)


class Counter(gdb.Breakpoint):
    """Counts passes without stopping the guest."""

    def __init__(self, spec: str):
        super().__init__(spec, internal=True)
        self.count = 0

    def stop(self) -> bool:
        self.count += 1
        return False


# scheduler-locking-waiver: the lane runs at 2 vCPUs
# (scripts/run_kernel_uart_wake_qemutest.sh), so no third vCPU is frozen.
def continue_bounded(threads_locked: bool) -> None:
    """Resume the guest, or with the lock only the selected vCPU, for at
    most STEP_TIMEOUT."""
    gdb.execute("set scheduler-locking " + ("on" if threads_locked else "off"))
    timer = interrupt_after(STEP_TIMEOUT)
    try:
        gdb.execute("continue")
    except (gdb.error, KeyboardInterrupt):
        pass
    finally:
        timer.cancel()


# A step the guest reaches deterministically, but whose host time depends on
# how much CPU QEMU gets. A fixed STEP_TIMEOUT failed under host load
# (GitHub issue #784: "CPU0 timer did not acquire the process-run lock",
# with CPU0 still running). Keep waiting while the selected vCPU's PC moves;
# stop at STEP_PROGRESS_CAP, or as soon as one STEP_TIMEOUT passes with no
# progress at all.
STEP_PROGRESS_CAP = 180.0


def continue_until_hit(bp, thread: int, threads_locked: bool) -> None:
    waited = 0.0
    last = None
    while bp.hit_count == 0 and waited < STEP_PROGRESS_CAP:
        continue_bounded(threads_locked)
        waited += STEP_TIMEOUT
        if bp.hit_count:
            return
        try:
            pc = thread_pc(thread)
        except gdb.error:
            return
        if pc == last:
            return
        last = pc


def thread_pc(thread: int) -> int:
    gdb.execute(f"thread {thread}", to_string=True)
    return int(gdb.parse_and_eval("$pc")) & 0xFFFFFFFFFFFFFFFF


def run_peer(connection: socket.socket) -> None:
    # The kernel admits the reader only after the peer console writer's view,
    # which ends with its seventeenth record. That chain starts with the busy
    # pair migrating, which waits for a third runnable context. The persistent
    # HTTPd may be asleep in accept, so it cannot provide that context.
    if not seen(lambda text: BUSY_PAIR_DONE in text, BOOT_TIMEOUT, boot_phase="busy-pair-done"):
        verdict(False, "the busy pair never finished before the peer chain")
        return
    if not seen(lambda text: PEER_CONSOLE_DONE in text, BOOT_TIMEOUT, boot_phase="peer-console-done"):
        verdict(False, "the peer console writer never delivered its last record")
        return
    # The wake window is reached only when another Ready process competes
    # with the reader on CPU 1. Neither a sleeping HTTPd nor an unpinned
    # shell job guarantees that placement. Wait for the fixture's affinity
    # syscall before starting the reader.
    for value in PEER_SPINNER:
        connection.sendall(bytes((value,)))
        time.sleep(0.01)
    if not seen(lambda text: PEER_SPINNER_READY in text, BOOT_TIMEOUT, boot_phase="peer-spinner-ready"):
        verdict(False, "/bin/peer-spin never pinned itself to CPU 1")
        return
    connection.sendall(PEER_COMMAND)
    if not seen(lambda text: PEER_READING in text, BOOT_TIMEOUT, boot_phase="peer-reader-ready"):
        verdict(False, "/bin/peer-tty never said it was reading the terminal "
                "on the secondary cpu")
        return
    # The marker is printed just before its first read; let it go to sleep.
    time.sleep(1.0)

    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    window = gdb.Breakpoint(PEER_WINDOW)
    window.condition = f"$_thread == {CPU1_THREAD}"
    push = gdb.Breakpoint(RING_PUSH)
    push.condition = f"$_thread == {CPU0_THREAD}"
    push.enabled = False

    # Byte 0 finds the reader asleep, which is the ordinary wake. Its read
    # of the next byte is what first brings it to the window. That it gets
    # there is the lane's premise: a reader with nothing else runnable on
    # its CPU never blocks, and this lane would then prove nothing.
    connection.sendall(PEER_LINE[:1])
    continue_bounded(False)
    if window.hit_count != 1:
        verdict(False, "the reader never went back to sleep on the secondary "
                "cpu after its first byte, so the cross-cpu window was not on "
                "its path; it needs something else runnable beside it")
        gdb.execute("detach")
        return
    last = len(PEER_LINE) - 1
    for index in range(1, len(PEER_LINE)):
        value = PEER_LINE[index:index + 1]
        connection.sendall(value)
        # The guest is stopped; QEMU's main loop still puts the byte in the
        # PL011 FIFO and raises the interrupt line, which is routed to CPU0.
        time.sleep(0.2)
        # Where CPU1 is stopped now: the breakpoint's own address, which gdb
        # places after the function's prologue, not the symbol's.
        window_pc = thread_pc(CPU1_THREAD)
        push.enabled = True
        gdb.execute(f"thread {CPU0_THREAD}", to_string=True)
        continue_bounded(True)
        pushed = push.hit_count == index
        held = thread_pc(CPU1_THREAD) == window_pc
        push.enabled = False
        if not pushed:
            verdict(False, f"byte {index} ({value!r}) never reached the ring "
                    "from CPU0's RX interrupt while CPU1 was held")
            gdb.execute("detach")
            return
        if not held:
            verdict(False, "gdb did not hold CPU1 in the window while CPU0 "
                    "ran, so this run proves nothing about the cross-cpu "
                    "order")
            gdb.execute("detach")
            return
        if index == last:
            window.delete()
            push.delete()
            gdb.execute("set scheduler-locking off")
            gdb.execute("detach")
            break
        continue_bounded(False)
        if window.hit_count != index + 1:
            gdb.execute("thread apply all bt 6")
            gdb.execute("x/4wx &terminal_settings")
            verdict(False,
                    f"byte {index} ({value!r}) of {PEER_LINE!r} was pushed "
                    "into the ring by CPU0 while the reader on CPU1 was past "
                    "its last lockless look, and the reader did not come back "
                    f"to read within {STEP_TIMEOUT:.0f} s: it is asleep "
                    "beside the byte (GitHub issue #547)")
            gdb.execute("set scheduler-locking off")
            gdb.execute("detach")
            return
    if not seen(lambda text: PEER_VERDICT in text, 15.0, response_phase="peer-line-verdict"):
        verdict(False, f"every byte of {PEER_LINE!r} was delivered, but the "
                "kernel never accepted the line /bin/peer-tty read")
        return
    peer_result = (f"bytes 1-{last} of {PEER_LINE!r} each reached the ring from "
                   "CPU0 while the reader was held on CPU1 between its last "
                   "lockless look and the lock, and each was read on the "
                   "secondary cpu")
    if MODE == "peer":
        print(f"PASS kernel/qemu peer-uart: {peer_result}", flush=True)
    else:
        verdict(True, peer_result)


def run_peer_net_wake(connection: socket.socket) -> None:
    # GitHub issue #829: the NetRx waiter blocks on CPU1 and is queued on
    # CPU1's own tick-wake list. gdb freezes CPU0 -- the strongest form of a
    # long core-0 mask -- and runs only CPU1. The waiter must come back to
    # its tag-6 syscall on CPU1 by CPU1's tick alone. The control kernel's
    # secondary tick wakes nothing of its own, and must not.
    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    control = MODE == "peer-net-control"
    net_block = gdb.Breakpoint("kernel_process_block_net")
    net_block.condition = f"$_thread == {CPU1_THREAD}"
    connection.sendall(PEER_NET_WAKE_COMMAND)
    continue_bounded(False)
    if net_block.hit_count != 1:
        verdict(False, "the peer fixture did not enter kernel_process_block_net")
        gdb.execute("detach")
        return
    net_block.delete()

    # Freeze CPU0 where it holds no lock: at its timer interrupt's entry.
    # Every kernel lock masks interrupts, so a CPU taking one holds none.
    # Stopped anywhere else, it may hold a pool lock CPU1's next syscall
    # spins on with interrupts masked, and no tick could run there at all.
    clean = gdb.Breakpoint("timer_irq_handler")
    clean.condition = f"$_thread == {CPU0_THREAD}"
    gdb.execute(f"thread {CPU0_THREAD}", to_string=True)
    continue_until_hit(clean, CPU0_THREAD, True)
    if clean.hit_count != 1:
        verdict(False, "CPU0 did not reach its timer interrupt to be frozen")
        gdb.execute("set scheduler-locking off")
        gdb.execute("detach")
        return
    clean.delete()

    # From here CPU0 stays stopped. CPU1's tick entering the wake of a due
    # record on its own list is the property; running the woken waiter is
    # the scheduler's business and is checked after CPU0 is released.
    resumed = gdb.Breakpoint("kernel_process_tick_wake_one")
    resumed.condition = f"$_thread == {CPU1_THREAD}"
    gdb.execute(f"thread {CPU1_THREAD}", to_string=True)
    for _ in range(3):
        if resumed.hit_count:
            break
        continue_bounded(True)
    woken = resumed.hit_count >= 1
    resumed.delete()
    gdb.execute("set scheduler-locking off")
    if control:
        gdb.execute("detach")
        if woken:
            verdict(False, "control kernel woke the CPU1 NetRx waiter while "
                    "CPU0 was stopped; the lane no longer tells the per-CPU "
                    "wake apart")
        else:
            verdict(True, "control kernel left the CPU1 NetRx waiter asleep "
                    "while CPU0 was stopped")
        return
    if not woken:
        gdb.execute("detach")
        verdict(False, "CPU1's own tick did not wake its NetRx waiter while "
                "CPU0 was stopped")
        return
    gdb.execute("detach")
    if not seen(lambda text: PEER_NET_WAKE_VERDICT in text, STEP_TIMEOUT, response_phase="peer-net-verdict"):
        verdict(False, "the peer NetRx waiter did not report its resume on cpu 1")
        return
    verdict(True, "CPU1's own tick woke its NetRx waiter while CPU0 was "
            "stopped, and it resumed on CPU1")


def run_scalar_buffering(connection: socket.socket) -> bool:
    # Stop at the next scalar call after the IRQ has delivered the first byte.
    # Seed the ring while every vCPU is stopped: this is the real queued-byte
    # state an IRQ leaves when the child is Ready rather than Blocked. No
    # later input may rescue a reader that ignores that queued byte.
    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    with open(os.environ["UART_WAKE_METADATA"], encoding="ascii") as metadata:
        constants = {entry["name"]: entry["value"]
                     for entry in json.load(metadata)["constants"]}
    capacity = constants["KERNEL_UART_RX_CAPACITY"]
    number = constants["AARCH64_NR_TAKIBI_UART_RX_WAIT"]
    scalar = gdb.Breakpoint("kernel_syscall_dispatch")
    scalar.condition = f"$x1 == {number}"
    connection.sendall(PAYLOAD[:1])
    continue_bounded(False)
    if scalar.hit_count != 1:
        scalar.delete()
        gdb.execute("detach")
        verdict(False, "the scalar reader did not resume after its first byte")
        return False

    def queue(bytes_to_queue: bytes) -> None:
        head = int(gdb.parse_and_eval("*(unsigned long *)&kernel_uart_rx_head"))
        tail = int(gdb.parse_and_eval("*(unsigned long *)&kernel_uart_rx_tail"))
        if head != tail or not 0 <= head < capacity:
            raise RuntimeError("scalar buffering window did not start with an empty ring")
        for value in bytes_to_queue:
            for name, byte in (("kernel_uart_rx_buf", value),
                               ("kernel_uart_rx_marks", 0),
                               ("kernel_uart_rx_columns", 0)):
                gdb.execute(f"set *((unsigned char *)&{name} + {head}) = {byte}")
            head = (head + 1) % capacity
        gdb.execute(f"set *(unsigned long *)&kernel_uart_rx_head = {head}")

    if os.environ.get("UART_WAKE_SCALAR_CONTROL") == "canonical":
        # Recreate the old unread canonical prefix at the same real scalar
        # syscall. This must fail without a new interrupt rescuing the wait.
        gdb.execute("set *(unsigned char *)&kernel_uart_rx_canonical = 1")
    queue(PAYLOAD[1:2])
    continue_bounded(False)
    if scalar.hit_count != 2:
        gdb.execute("thread apply all bt 6")
        scalar.delete()
        gdb.execute("detach")
        verdict(False, "queued scalar UART byte was not returned before a later input byte")
        return False
    # The next scalar call can now read the suffix already queued, proving
    # a burst keeps its order as well as the one-byte no-new-interrupt case.
    queue(PAYLOAD[2:])
    scalar.delete()
    gdb.execute("detach")
    if not seen(lambda text: b"uart rx: scheduler block+wake ok" in text,
                BOOT_TIMEOUT, boot_phase="scalar-boot-report"):
        verdict(False, "the scalar reader did not consume its queued suffix in order")
        return False
    print(f"PASS {LABEL}: scalar IRQ delivery followed by queued prefix "
          "and suffix preserved every byte without another interrupt", flush=True)
    return True


def run() -> None:
    connection = connect(time.monotonic() + 30)
    threading.Thread(target=reader, args=(connection,), daemon=True).start()
    # Not the boot's first, interactive shell: nothing else can run beside
    # it, so its read never sleeps. It waits for the interrupt in the kernel
    # and runs the read again, which finds any byte in the ring. The window
    # only exists when the read BLOCKS, which takes something else to run,
    # and that is the persistent shell /etc/inittab starts beside the busy
    # pair. Both stalls were at that shell's prompt. So the first shell is
    # sent away, and so is the payload that follows it, the way the ash
    # lane's driver does.
    if not seen(lambda text: SHELL_READY in text, BOOT_TIMEOUT, boot_phase="first-shell"):
        verdict(False, "the boot never reached the interactive shell's prompt")
        return
    connection.sendall(b"exit\n")
    if not seen(lambda text: PAYLOAD_READY in text, BOOT_TIMEOUT, boot_phase="payload-ready"):
        verdict(False, "the payload never asked for its input")
        return
    if not run_scalar_buffering(connection):
        return
    if not seen(lambda text: PERSISTENT_READY in text, BOOT_TIMEOUT, boot_phase="persistent-shell"):
        verdict(False, "the persistent shell never reached its prompt")
        return
    # The marker is printed on the read's way to sleep; let it get there.
    time.sleep(1.0)
    if MODE.startswith("peer"):
        run_peer(connection)
        if seen(lambda text: PEER_VERDICT in text, 1.0):
            run_peer_net_wake(connection)
        return

    # A read blocks only when something else is Ready. Beside this shell
    # there is only the busy pair's survivor, and two CPUs hold both. The
    # lane used to pass anyway because init's sleep retried in EL1 and kept
    # a CPU, which left the survivor Ready; once a sleep gave the CPU up,
    # only 1 of 17 reads blocked. So start a real third runnable context: a
    # background EL0 spin that never makes a syscall. Paced, because the
    # line is longer than the PL011 FIFO.
    for value in SPINNER:
        connection.sendall(bytes((value,)))
        time.sleep(0.01)
    time.sleep(1.5)

    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    window = gdb.Breakpoint(WINDOW)
    # The lane's premise, checked rather than assumed: the window only exists
    # when the read goes on to BLOCK. A first version of this lane typed into
    # a shell whose reads never blocked, and it passed on the kernel with the
    # lost wakeup. Each window pass but the last is resumed inside this run,
    # so that many block returns are required.
    blocking = Counter("kernel_syscall_block_return")
    for index, value in enumerate(COMMAND):
        connection.sendall(bytes([value]))
        # The guest is stopped; QEMU's main loop still moves the byte into
        # the PL011 FIFO and raises the interrupt line meanwhile.
        time.sleep(0.2)
        timer = interrupt_after(STEP_TIMEOUT)
        try:
            gdb.execute("continue")
        except (gdb.error, KeyboardInterrupt):
            pass
        finally:
            timer.cancel()
        if window.hit_count != index + 1:
            gdb.execute("thread apply all bt 6")
            gdb.execute("x/4wx &terminal_settings")
            verdict(False,
                    f"byte {index} ({bytes([value])!r}) of {COMMAND!r} was sent "
                    "while the shell was on its way to sleep, and the shell "
                    f"did not come back to read within {STEP_TIMEOUT:.0f} s: "
                    "it is asleep beside a byte that is already in the ring "
                    "(GitHub issue #546)")
            gdb.execute("detach")
            return
    blocked = blocking.count
    window.delete()
    blocking.delete()
    gdb.execute("detach")
    if blocked < len(COMMAND) - 1:
        verdict(False, f"only {blocked} of the {len(COMMAND) - 1} reads resumed "
                "inside the window went on to block, so the window this lane "
                "opens was not on their path. It would pass on a kernel with "
                "the lost wakeup: the reader needs something else runnable "
                "beside it")
        return
    if not seen(answered, 15.0, response_phase="shell-answer"):
        verdict(False, f"every byte of {COMMAND!r} was read, but `{ANSWER}` "
                "never came back from the shell")
        return
    verdict(True, f"all {len(COMMAND)} bytes of {COMMAND!r} arrived inside "
            "the read's window before sleeping, each was read, and the "
            "shell answered")


try:
    run()
except Exception as error:  # a verdict file must exist either way
    verdict(False, f"the check itself failed: {error!r}")
