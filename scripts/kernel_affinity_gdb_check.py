"""GitHub issue #9: the migration gate, watched from outside the kernel.

Runs inside gdb-multiarch (`gdb -batch -x`), started by
scripts/run_kernel_affinity_gdb_qemutest.sh, which launches QEMU and the
network peer and passes the ports and paths in the environment.

A process on a peer because its affinity mask put it there runs every
syscall there except those the kernel's refusal list (syscall_peer_refused,
GitHub issue #583) keeps on core 0. Those are rewound, and the process is
handed to core 0, which runs the syscall from the start.
Nothing at EL0 can tell where a syscall ran: /bin/affinity's execve answers
the same either way. So this watches the kernel instead, without the kernel
printing anything for it.

The probe pins itself to CPU 1 and asks for execve, which is outside the
table. The only breakpoint armed while it runs is the gate's own tail,
kernel_syscall_migrate_return, so the probe's many other syscalls run at
full speed. That breakpoint must be hit on CPU 1, and the rewound frame
must hold that syscall's number in its saved x8. Only then is core 0's rerun
watched for: kernel_syscall_dispatch entered on CPU 0 with the same number. A
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
PINNED = b"affinity: pinned to cpu 1, where execve, outside the peer-safe table, still answered"
# The entry addresses themselves, where x0 and x1 are still the call's
# arguments. With a debug image (KERNEL_QEMU_AFFINITY_GDB_ELF), a function
# breakpoint would land after the prologue, where they may be gone.
GATE = "*kernel_syscall_migrate_return"
DISPATCH = "*kernel_syscall_dispatch"
# The syscall /bin/affinity uses to make the gate fire. It must stay
# OUTSIDE syscall_peer_safe: this was uname until entry 6 admitted it, and
# getcwd until the increment after that, rt_sigprocmask until #570 admitted
# it, and kill until #583's first increment. The check holds the two together.
MIGRATED_SYSCALL = 221
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
    # GitHub issue #585: registers only, no frame read.
    #
    # This used to select the probe's gate hit by reading the rewound frame's
    # saved x8 at `$x0 + 64` and skipping any hit whose frame it could not
    # read, on the reasoning that such a hit was another process's. That
    # reasoning was wrong, and about one boot in ten proved it: gdb reads
    # guest memory through the translation the stopped CPU has active, which
    # at the gate is the PROCESS's root -- and a process root maps the kernel
    # image's identity block, not every page the page allocator hands out for
    # a kernel stack. Whether a given boot's stack run lands inside that block
    # is luck, so the probe's OWN hit came back `Cannot access memory at
    # address 0x406afd10` and was counted as somebody else's.
    #
    # The syscall number does not have to come out of memory. The dispatcher
    # takes it as its second argument, which the rerun breakpoint below
    # already matches on, so the same condition identifies the CALL on CPU 1
    # before the gate fires for it. Three register-only conditions, in the
    # order they must happen:
    #
    #   1. kernel_syscall_dispatch entered on CPU 1 with this syscall,
    #   2. kernel_syscall_migrate_return reached on CPU 1 after that,
    #   3. kernel_syscall_dispatch entered on CPU 0 with the same syscall.
    #
    # Other fixtures still take the gate throughout the session -- that has
    # not changed -- but (1) is what says the next (2) belongs to the probe.
    asked = gdb.Breakpoint(DISPATCH)
    asked.condition = (f"$x1 == {MIGRATED_SYSCALL} && "
                       f"$_thread == {CPU1_THREAD}")
    # The probe's line fits the 16-byte PL011 FIFO, so it can go at once
    # while the guest is held.
    connection.sendall(COMMAND)
    continue_bounded()
    if asked.hit_count == 0:
        verdict(False, "/bin/affinity never asked execve from CPU 1, so "
                f"the migration gate had nothing to fire for. {where()}. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    asked.delete()

    gate = gdb.Breakpoint(GATE)
    gate.condition = f"$_thread == {CPU1_THREAD}"
    continue_bounded()
    if gate.hit_count == 0:
        verdict(False, "/bin/affinity asked execve from CPU 1 and the "
                "migration gate did not fire for it: that syscall was not "
                f"handed to core 0. {where()}. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    gate.delete()

    rerun = gdb.Breakpoint(DISPATCH)
    rerun.condition = f"$x1 == {MIGRATED_SYSCALL} && $_thread == {CPU0_THREAD}"
    continue_bounded()
    if rerun.hit_count != 1:
        verdict(False, "the gate handed execve off on CPU1, but core 0 never "
                f"dispatched it again. {where()}. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    rerun.delete()
    gdb.execute("detach")

    if not seen(lambda text: PINNED in text, STEP_TIMEOUT):
        # Stop the machine again only to say where it is.
        gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
        verdict(False, "core 0 reran execve, but /bin/affinity never printed "
                f"its pinned line. {where()}. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    verdict(True, "execve asked from CPU1 took the migration gate there, "
            "watched as three register-only steps in order, and core 0 "
            "dispatched it again; "
            "/bin/affinity then reported its answer")


try:
    run()
except Exception as error:  # noqa: BLE001 -- the verdict file is the interface
    verdict(False, f"the gdb check stopped: {error}")
