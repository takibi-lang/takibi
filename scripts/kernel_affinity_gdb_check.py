"""GitHub issue #9: the migration gate, watched from outside the kernel.

Runs inside gdb-multiarch (`gdb -batch -x`), started by
scripts/run_kernel_affinity_gdb_qemutest.sh, which launches QEMU and the
network peer and passes the ports and paths in the environment.

A process on a peer because its affinity mask put it there may run only the
syscalls the kernel's peer-safety table allows. Any other is rewound, and
the process is handed to core 0, which runs the syscall from the start.
Nothing at EL0 can tell where a syscall ran: /bin/affinity's uname answers
the same either way. So this watches the kernel instead, without the kernel
printing anything for it.

The probe pins itself to CPU 1 and asks for uname, which is outside the
table. The only breakpoint armed while it runs is the gate's own tail,
kernel_syscall_migrate_return, so the probe's many other syscalls run at
full speed. That breakpoint must be hit on CPU 1, and the rewound frame
must hold syscall number 160 in its saved x8. Only then is core 0's rerun
watched for: kernel_syscall_dispatch entered on CPU 0 with x1 = 160. A
kernel without the gate never reaches the first breakpoint; one that
rewound the frame but never gave the process to core 0 never reaches the
second.
"""

import os
import signal
import socket
import threading
import time

import gdb


SERIAL_PORT = int(os.environ["AFFINITY_GDB_SERIAL_PORT"])
GDB_PORT = int(os.environ["AFFINITY_GDB_GDB_PORT"])
UART_LOG = os.environ["AFFINITY_GDB_UART_LOG"]
VERDICT = os.environ["AFFINITY_GDB_VERDICT"]
INIT_LISTENER = os.environ["AFFINITY_GDB_INIT_LISTENER"]
NETWORK_READY = os.environ["AFFINITY_GDB_NETWORK_READY"]
BOOT_TIMEOUT = float(os.environ.get("AFFINITY_GDB_BOOT_TIMEOUT", "120"))
STEP_TIMEOUT = 60.0

LABEL = "kernel/qemu affinity-gdb"
SHELL_READY = b"interactive shell: uart blocked\n"
COMMAND = b"/bin/affinity\n"
PINNED = b"affinity: pinned to cpu 1, where uname, outside the peer-safe table, still answered"
# The entry addresses themselves, where x0 and x1 are still the call's
# arguments. With a debug image (KERNEL_QEMU_AFFINITY_GDB_ELF), a function
# breakpoint would land after the prologue, where they may be gone.
GATE = "*kernel_syscall_migrate_return"
DISPATCH = "*kernel_syscall_dispatch"
UNAME = 160
# user_entry.S loads the syscall number for dispatch from the saved x8,
# eight words into the exception frame.
FRAME_X8_OFFSET = 64
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


def interrupt_after(seconds: float) -> threading.Timer:
    timer = threading.Timer(seconds, lambda: os.kill(os.getpid(), signal.SIGINT))
    timer.start()
    return timer


def continue_bounded(budget: float = STEP_TIMEOUT) -> None:
    """Resume both vCPUs for at most `budget` seconds.

    The budget is an argument because the gate-selection loop below resumes
    repeatedly: a fixed per-resume bound there would let one lap spend the
    whole step timeout after the loop's own deadline had passed, which is lane
    time spent learning nothing.
    """
    timer = interrupt_after(max(budget, 1.0))
    try:
        gdb.execute("continue")
    except (gdb.error, KeyboardInterrupt):
        pass
    finally:
        timer.cancel()


def register(name: str) -> int:
    return int(gdb.parse_and_eval(f"${name}")) & 0xFFFFFFFFFFFFFFFF


def read_u64(address: int) -> int:
    data = gdb.selected_inferior().read_memory(address, 8)
    return int.from_bytes(bytes(data), "little")


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
    if not seen(lambda text: SHELL_READY in text, BOOT_TIMEOUT):
        verdict(False, "the boot never reached the interactive shell's prompt")
        return

    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    gate = gdb.Breakpoint(GATE)
    # The probe's line fits the 16-byte PL011 FIFO, so it can go at once
    # while the guest is held.
    connection.sendall(COMMAND)

    # The gate is not the probe's alone. Every fixture that runs on a peer
    # reaches it for any syscall outside the peer-safety table -- and
    # /bin/peer-read's openat and close are outside it, so its reads take the
    # gate throughout this session. An earlier version of this check assumed
    # the first hit was the probe's uname; it read another process's frame
    # instead and died with "Cannot access memory".
    #
    # So select rather than assume: keep resuming until a hit is the probe's
    # own -- CPU 1, with uname in the rewound frame's saved x8. A hit whose
    # frame cannot be read is somebody else's too, and is passed over the same
    # way. A gdb breakpoint CONDITION cannot do this: reading the frame there
    # would raise inside the condition on exactly the hits this has to skip.
    deadline = time.monotonic() + STEP_TIMEOUT
    ours = False
    foreign = 0
    while not ours and time.monotonic() < deadline:
        continue_bounded(deadline - time.monotonic())
        if gate.hit_count == 0:
            break
        thread = gdb.selected_thread()
        if thread is None or thread.num != CPU1_THREAD:
            foreign += 1
            continue
        try:
            number = read_u64(register("x0") + FRAME_X8_OFFSET)
        except (gdb.MemoryError, gdb.error):
            foreign += 1
            continue
        if number == UNAME:
            ours = True
        else:
            foreign += 1
    if not ours:
        verdict(False, f"/bin/affinity ran without the migration gate firing "
                f"for uname on CPU 1 (hits={gate.hit_count}, "
                f"{foreign} of them other processes'): uname asked from CPU 1 "
                f"was not handed to core 0. {where()}. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    gate.enabled = False

    rerun = gdb.Breakpoint(DISPATCH)
    rerun.condition = f"$x1 == {UNAME} && $_thread == {CPU0_THREAD}"
    continue_bounded()
    if rerun.hit_count != 1:
        verdict(False, "the gate handed uname off on CPU1, but core 0 never "
                f"dispatched it again. {where()}. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    gate.delete()
    rerun.delete()
    gdb.execute("detach")

    if not seen(lambda text: PINNED in text, STEP_TIMEOUT):
        # Stop the machine again only to say where it is.
        gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
        verdict(False, "core 0 reran uname, but /bin/affinity never printed "
                f"its pinned line. {where()}. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    verdict(True, "uname asked from CPU1 took the migration gate there, with "
            "syscall 160 in the rewound frame, and core 0 dispatched it again; "
            "/bin/affinity then reported its answer")


try:
    run()
except Exception as error:  # noqa: BLE001 -- the verdict file is the interface
    verdict(False, f"the gdb check stopped: {error}")
