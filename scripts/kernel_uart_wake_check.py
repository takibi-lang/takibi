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

output = bytearray()
output_lock = threading.Lock()


def verdict(ok: bool, message: str) -> None:
    line = f"{'PASS' if ok else 'FAIL'} kernel/qemu uart-wake: {message}"
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


def interrupt_after(seconds: float) -> threading.Timer:
    timer = threading.Timer(seconds, lambda: os.kill(os.getpid(), signal.SIGINT))
    timer.start()
    return timer


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

    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    window = gdb.Breakpoint(WINDOW)
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
    window.delete()
    gdb.execute("detach")
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
