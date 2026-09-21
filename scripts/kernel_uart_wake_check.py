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
"""

import os
import signal
import socket
import threading
import time

import gdb


SERIAL_PORT = int(os.environ["UART_WAKE_SERIAL_PORT"])
GDB_PORT = int(os.environ["UART_WAKE_GDB_PORT"])
UART_LOG = os.environ["UART_WAKE_UART_LOG"]
VERDICT = os.environ["UART_WAKE_VERDICT"]
INIT_LISTENER = os.environ["UART_WAKE_INIT_LISTENER"]
NETWORK_READY = os.environ["UART_WAKE_NETWORK_READY"]
BOOT_TIMEOUT = float(os.environ.get("UART_WAKE_BOOT_TIMEOUT", "120"))
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
LABEL = "kernel/qemu peer-uart-wake" if MODE == "peer" else "kernel/qemu uart-wake"
PEER_COMMAND = b"/bin/peer-tty\n"
PEER_CONSOLE_DONE = b"peer user console: record=17/17 "
BUSY_PAIR_DONE = b"workload: busy pair done\n"
PEER_READING = b"workload: peer tty reading the terminal on the secondary cpu\n"
PEER_LINE = b"peer-tty-line-ok\n"
PEER_VERDICT = b"workload: peer tty read its 17-byte line"
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
            if (not published_init and
                    b"linux socket: listener ready port=8080\n" in seen):
                open(INIT_LISTENER, "w").close()
                published_init = True
            if not published_network and b"virtio net: link ready " in seen:
                open(NETWORK_READY, "w").close()
                published_network = True


def seen(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with output_lock:
            text = bytes(output)
        if predicate(text):
            return True
        time.sleep(0.1)
    return False


def answered(text: bytes) -> bool:
    lines = text.decode("ascii", errors="replace").replace("\r", "").splitlines()
    return any(line.removeprefix("/ # ") == ANSWER for line in lines)


class Counter(gdb.Breakpoint):
    """Counts passes without stopping the guest."""

    def __init__(self, spec: str):
        super().__init__(spec, internal=True)
        self.count = 0

    def stop(self) -> bool:
        self.count += 1
        return False


def interrupt_after(seconds: float) -> threading.Timer:
    timer = threading.Timer(seconds, lambda: os.kill(os.getpid(), signal.SIGINT))
    timer.start()
    return timer


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


def thread_pc(thread: int) -> int:
    gdb.execute(f"thread {thread}", to_string=True)
    return int(gdb.parse_and_eval("$pc")) & 0xFFFFFFFFFFFFFFFF


def run_peer(connection: socket.socket) -> None:
    # The kernel admits the reader only after the peer console writer's view,
    # which ends with its seventeenth record. That chain starts with the busy
    # pair migrating, which waits for a third runnable context. The persistent
    # HTTPd may be asleep in accept, so it cannot provide that context.
    if not seen(lambda text: BUSY_PAIR_DONE in text, BOOT_TIMEOUT):
        verdict(False, "the busy pair never finished before the peer chain")
        return
    if not seen(lambda text: PEER_CONSOLE_DONE in text, BOOT_TIMEOUT):
        verdict(False, "the peer console writer never delivered its last record")
        return
    # The wake window is reached only when another Ready process competes
    # with the reader on CPU 1. Neither a sleeping HTTPd nor an unpinned
    # shell job guarantees that placement. Wait for the fixture's affinity
    # syscall before starting the reader.
    for value in PEER_SPINNER:
        connection.sendall(bytes((value,)))
        time.sleep(0.01)
    if not seen(lambda text: PEER_SPINNER_READY in text, BOOT_TIMEOUT):
        verdict(False, "/bin/peer-spin never pinned itself to CPU 1")
        return
    connection.sendall(PEER_COMMAND)
    if not seen(lambda text: PEER_READING in text, BOOT_TIMEOUT):
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
            verdict(False,
                    f"byte {index} ({value!r}) of {PEER_LINE!r} was pushed "
                    "into the ring by CPU0 while the reader on CPU1 was past "
                    "its last lockless look, and the reader did not come back "
                    f"to read within {STEP_TIMEOUT:.0f} s: it is asleep "
                    "beside the byte (GitHub issue #547)")
            gdb.execute("set scheduler-locking off")
            gdb.execute("detach")
            return
    if not seen(lambda text: PEER_VERDICT in text, 15.0):
        verdict(False, f"every byte of {PEER_LINE!r} was delivered, but the "
                "kernel never accepted the line /bin/peer-tty read")
        return
    verdict(True, f"bytes 1-{last} of {PEER_LINE!r} each reached the ring from "
            "CPU0 while the reader was held on CPU1 between its last lockless "
            "look and the lock, and each was read on the secondary cpu")


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
    if not seen(lambda text: SHELL_READY in text, BOOT_TIMEOUT):
        verdict(False, "the boot never reached the interactive shell's prompt")
        return
    connection.sendall(b"exit\n")
    if not seen(lambda text: PAYLOAD_READY in text, BOOT_TIMEOUT):
        verdict(False, "the payload never asked for its input")
        return
    connection.sendall(PAYLOAD)
    if not seen(lambda text: PERSISTENT_READY in text, BOOT_TIMEOUT):
        verdict(False, "the persistent shell never reached its prompt")
        return
    # The marker is printed on the read's way to sleep; let it get there.
    time.sleep(1.0)
    if MODE == "peer":
        run_peer(connection)
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
    if not seen(answered, 15.0):
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
