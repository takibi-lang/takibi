"""GitHub issue #571: wait4's two walks, held apart with gdb.

Runs inside gdb-multiarch (`gdb -batch -x`), started by
scripts/run_kernel_affinity_gdb_qemutest.sh with
KERNEL_QEMU_AFFINITY_GDB_MODE=reap, which launches QEMU and the network peer
and passes the ports and paths in the environment. The boot, the network peer
and the /bin/affinity command are the gate mode's; only what gdb does differs.

wait4(pid) decides its answer from two walks of the caller's child list:

    collectable = kernel_process_child_waitable_pid(pid)   # is it a zombie?
    ...
    if (kernel_process_current_has_live_child()) { block }
    return ECHILD

kernel_process_child_exit moves a child from Running to Exited on whichever
CPU it is on. While those two walks were unlocked, a child that crossed that
transition BETWEEN them was a zombie to neither question -- the first walk saw
it Running, so not collectable, and the second saw it Exited, so not live --
and wait4 answered ECHILD for a child a second wait4 collected. Measured at
about 3 in 40 `kernelcheck-qemu-main` runs before the two walks were put under
one hold of the process-run lock.

A rate is not a regression test. This makes the interleaving on purpose:
CPU0 is stopped between the two walks, and only CPU1 is allowed to run.

There are exactly two outcomes worth reporting, and they are not "it passed"
and "it failed to happen":

  - CPU1 publishes the exit while CPU0 stands between the walks. Then the
    window is open, and what wait4 answers says whether it is the defect.
    ECHILD is the defect, reproduced.
  - CPU1 cannot publish it, because the walk CPU0 is inside holds the
    process-run lock that the exit needs. That is the repair, and the
    evidence for it is WHERE CPU1 stopped: inside the lock. A check that
    reported only "the window was never entered" would read the same whether
    the lock excluded the peer or the fixture simply never ran, so this names
    the stopping place rather than the absence.
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
# How long CPU1 alone is given to finish an exit that nothing is blocking.
# Short, because the whole claim of the repaired kernel is that this expires.
PEER_BUDGET = 12.0

LABEL = "kernel/qemu affinity-reap"
SHELL_READY = b"interactive shell: uart blocked\n"
COMMAND = b"/bin/affinity\n"
# Printed by the probe's SAME-CORE pair, immediately before it forks the
# spinner that pins itself to CPU 1. It is how a kill(2) belonging to the
# cross-core arrangement is told from the same-core one that precedes it.
PEER_ARRANGEMENT = b"affinity: the napping spinner took the SIGTERM"
# kill(2)'s delivery. Taken on core 0 after the line above, this is the
# probe signalling the child it is about to wait4 -- and the moment to
# freeze CPU1, so that the child is certainly still alive when core 0
# reaches the walk below. Without that freeze the child usually exits
# first, the first walk answers "already a zombie", and the interleaving
# this exists to hold open never occurs.
KILL = "kernel_process_signal_send"
# The wait4 arm's first walk, and its only production caller. Stopping on its
# RETURN parks CPU0 between the two walks.
FIRST_WALK = "kernel_process_child_waitable_pid"
# The secondary publishing that it no longer stands on the exiting child's
# kernel stack: the exit is complete by the time this is reached.
PEER_IDLE = "kernel_process_stack_idle_complete"
# Where CPU1 is parked before it is frozen, and it has to be a place holding
# NO lock. Freezing a core wherever it happens to be freezes whatever it is
# holding, and this check then deadlocks the core it wants to watch: CPU0
# takes the process-run lock inside wait4 and spins on a core gdb has
# stopped. Seen as `Thread 1 received signal SIGINT ... in spin_lock` with a
# verdict blaming the fixture. Two places qualify: the idle loop's entry to
# the scheduler, reached once per idle wakeup and before it takes anything,
# and the syscall dispatcher's entry, reached before a syscall takes
# anything. The second is the one that matters since GitHub issue #592: a
# child that pins itself to CPU 1 now moves there at once, so CPU 1 is
# usually RUNNING the spinner when core 0 sends its kill. Parking only at
# the idle entry then let CPU 1 run the spinner until it exited on its own,
# and the child was a zombie before the walk this check exists to hold open
# -- the failure was the fixture ending its own subject, about 1 run in 4.
# The spinner makes a syscall on every iteration, so it stops at the
# dispatcher, alive.
PEER_PARKS = ("kernel_process_secondary_start", "kernel_syscall_dispatch")
# Step 3/8 of the syscall return, whose second argument is the value the
# dispatcher decided on.
RESUME = "kernel_syscall_resume_return"
LINUX_ECHILD = 0xFFFFFFFFFFFFFFF6
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
                text = bytes(output)
            if (not published_init and
                    b"linux socket: listener ready port=8080\n" in text):
                open(INIT_LISTENER, "w").close()
                published_init = True
            if not published_network and b"virtio net: link ready " in text:
                open(NETWORK_READY, "w").close()
                published_network = True


def seen(needle: bytes, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with output_lock:
            if needle in bytes(output):
                return True
        time.sleep(0.05)
    return False


def interrupt_after(seconds: float) -> threading.Timer:
    timer = threading.Timer(seconds, lambda: os.kill(os.getpid(), signal.SIGINT))
    timer.start()
    return timer


def run_bounded(command: str, budget: float = STEP_TIMEOUT) -> bool:
    """Run one gdb command for at most `budget` seconds.

    False means it did not complete: the timer's SIGINT stopped it, or gdb
    refused it. Every step here has a caller that can carry on without it, so
    a stall becomes a named verdict rather than a lane that has to time out.
    """
    timer = interrupt_after(max(budget, 1.0))
    try:
        gdb.execute(command)
    except (gdb.error, KeyboardInterrupt):
        return False
    finally:
        timer.cancel()
    return True


def register(name: str) -> int:
    return int(gdb.parse_and_eval(f"${name}")) & 0xFFFFFFFFFFFFFFFF


def uart_tail() -> str:
    with output_lock:
        return bytes(output[-200:]).decode("ascii", errors="replace")


def symbol_at(thread: int) -> str:
    gdb.execute(f"thread {thread}", to_string=True)
    pc = register("pc")
    return gdb.execute(f"info symbol {pc:#x}", to_string=True).strip()


def run() -> None:
    connection = connect(time.monotonic() + 30)
    threading.Thread(target=reader, args=(connection,), daemon=True).start()
    if not seen(SHELL_READY, BOOT_TIMEOUT):
        verdict(False, "the boot never reached the interactive shell's prompt")
        return

    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"target remote 127.0.0.1:{GDB_PORT}")
    kill = gdb.Breakpoint(KILL)
    kill.condition = f"$_thread == {CPU0_THREAD}"
    # The probe's line fits the 16-byte PL011 FIFO, so it can go at once
    # while the guest is held.
    connection.sendall(COMMAND)

    # Select the kill that belongs to the cross-core arrangement: the one
    # taken after the same-core pair has reported. Earlier hits are that
    # pair's, and are resumed without being examined.
    deadline = time.monotonic() + STEP_TIMEOUT
    kills = 0
    armed = False
    while not armed and time.monotonic() < deadline:
        gdb.execute("set scheduler-locking off")
        if not run_bounded("continue", deadline - time.monotonic()):
            break
        if gdb.selected_thread() is None or kill.hit_count == kills:
            break
        kills = kill.hit_count
        with output_lock:
            armed = PEER_ARRANGEMENT in bytes(output)
    if not armed:
        verdict(False, "/bin/affinity never reached the kill(2) of its "
                f"cross-core arrangement ({kills} kills seen on core 0), so "
                f"there was no peer reap to hold apart. "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return

    kill.delete()
    # Park CPU1 somewhere it holds no lock BEFORE freezing it, by freezing
    # CPU0 first and letting only CPU1 run. CPU0 is stopped at the entry of
    # kernel_process_signal_send and holds nothing itself, so nothing of
    # CPU1's can be waiting on it.
    gdb.execute(f"thread {CPU1_THREAD}", to_string=True)
    gdb.execute("set scheduler-locking on")
    parks = [gdb.Breakpoint(name) for name in PEER_PARKS]
    for park in parks:
        park.condition = f"$_thread == {CPU1_THREAD}"
    parked = (run_bounded("continue", PEER_BUDGET) and
              any(park.hit_count > 0 for park in parks))
    for park in parks:
        park.delete()
    if not parked:
        gdb.execute("set scheduler-locking off")
        verdict(False, "CPU1 never reached a lock-free entry it is parked "
                f"at, so it could not be frozen without whatever lock it "
                f"holds. UART tail: {uart_tail()!r}")
        gdb.execute("detach")
        return
    # CPU1 is now stopped holding nothing; selecting CPU0 freezes it there.
    gdb.execute(f"thread {CPU0_THREAD}", to_string=True)
    gdb.execute("set scheduler-locking on")
    walk = gdb.Breakpoint(FIRST_WALK)
    walk.condition = f"$_thread == {CPU0_THREAD}"

    deadline = time.monotonic() + STEP_TIMEOUT
    hits = 0
    entered = False
    while not entered and time.monotonic() < deadline:
        if not run_bounded("continue", deadline - time.monotonic()):
            break
        if gdb.selected_thread() is None or walk.hit_count == hits:
            break
        hits = walk.hit_count
        # Return to the wait4 arm. CPU0 now stands between the two walks,
        # with the first one's answer in x0.
        if not run_bounded("finish"):
            continue
        # The child is frozen, so a zombie here belongs to some other
        # wait4 and this is not the call under test.
        entered = (register("x0") & 1) == 0
    if not entered:
        verdict(False, "core 0 was never caught between wait4's two walks "
                f"with its peer child still running ({hits} hits on "
                f"{FIRST_WALK} while CPU1 was frozen). "
                f"UART tail: {uart_tail()!r}")
        gdb.execute("set scheduler-locking off")
        walk.delete()
        gdb.execute("detach")
        return

    # Hold CPU0 exactly there and let only CPU1 run. Its child has a pending
    # SIGTERM, so its next syscall exits it -- which is the transition the
    # second walk is about to read.
    gdb.execute(f"thread {CPU1_THREAD}", to_string=True)
    peer_idle = gdb.Breakpoint(PEER_IDLE)
    peer_idle.condition = f"$_thread == {CPU1_THREAD}"
    run_bounded("continue", PEER_BUDGET)
    published = peer_idle.hit_count > 0
    peer_idle.delete()
    peer_stopped_at = None if published else symbol_at(CPU1_THREAD)
    gdb.execute(f"thread {CPU0_THREAD}", to_string=True)

    answered = None
    if published:
        # The peer's exit landed inside the window. Let CPU0 finish the
        # syscall it is in the middle of and read what it hands back.
        walk.delete()
        resume = gdb.Breakpoint(RESUME)
        resume.condition = f"$_thread == {CPU0_THREAD}"
        gdb.execute("set scheduler-locking off")
        run_bounded("continue")
        if resume.hit_count > 0:
            answered = register("x1")
        resume.delete()
    else:
        walk.delete()
    gdb.execute("set scheduler-locking off")
    gdb.execute("detach")

    if peer_stopped_at is not None:
        if "lock" in peer_stopped_at or "mutex" in peer_stopped_at:
            verdict(True, "with CPU0 stopped between wait4's two walks, CPU1 "
                    f"could not publish its child's exit: it waits at "
                    f"{peer_stopped_at}. The pair of walks and the peer's "
                    "Running-to-Exited transition exclude each other, so the "
                    "child is Running to both walks or Exited to both, and "
                    "the ECHILD that belonged to neither cannot be reached")
            return
        verdict(False, "CPU1 did not publish its child's exit while CPU0 was "
                f"stopped between the walks, but it is at {peer_stopped_at}, "
                "which is not the run lock. Something other than the repair "
                f"stopped it, so this run proves nothing. "
                f"UART tail: {uart_tail()!r}")
        return
    if answered is None:
        verdict(False, "CPU1 published its child's exit inside the window, "
                "but core 0 never reached a syscall return, so what wait4 "
                f"answered was not read. UART tail: {uart_tail()!r}")
        return
    if answered == LINUX_ECHILD:
        verdict(False, "REPRODUCED GitHub issue #571: with CPU0 stopped "
                "between wait4's two walks and the peer child exited in "
                "between, wait4 answered ECHILD for a child that was "
                "collectable")
        return
    verdict(True, "with CPU0 stopped between wait4's two walks and the peer "
            f"child exited in between, wait4 answered {answered:#x}, not "
            "ECHILD")


try:
    run()
except Exception as error:  # noqa: BLE001 -- the verdict file is the interface
    verdict(False, f"the gdb check stopped: {error}")
