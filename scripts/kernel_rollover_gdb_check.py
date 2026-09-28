"""GitHub issue #632: an exec that needs an ASID rollover and cannot stop the world.

Runs inside gdb-multiarch (`gdb -batch -x`), started by
scripts/run_kernel_affinity_gdb_qemutest.sh with
KERNEL_QEMU_AFFINITY_GDB_MODE=rollover, which launches QEMU and the network
peer and passes the ports and paths in the environment.

kernel_process_activate_stable_root is where exec (and the boot fixtures)
switch to a new address space. When the ASID counter is exhausted, it has to
stop every other core to roll it over. If another core already holds the
stop, `world_stop_begin` answers Busy, and it answered Partial when a core
did not acknowledge in time. Both used to fail-stop the whole kernel. #584's
long churn run hit that on RPi5, 2 runs in 2, at the counter's first wrap
under a real workload -- and not in a run of the same length without a
debugger stop, which is why a rate is no regression test here.

This makes the answer happen on purpose. gdb sets the debugger-owned
`kernel_process_rollover_busy_injections` to BUSY_STOPS and detaches. The
next stable activation then finds the counter exhausted and meets that many
Busy answers before it stops the world for real, which is exactly what it
would meet while another core's rollover held the stop. The repaired kernel
retries, rolls over, prints how many Busy answers it waited out, and the boot
goes on to finish. The kernel that fail-stopped prints an oops instead.
"""

import os
import socket
import threading
import time

import gdb


SERIAL_PORT = int(os.environ["AFFINITY_GDB_SERIAL_PORT"])
UART_LOG = os.environ["AFFINITY_GDB_UART_LOG"]
VERDICT = os.environ["AFFINITY_GDB_VERDICT"]
INIT_LISTENER = os.environ["AFFINITY_GDB_INIT_LISTENER"]
NETWORK_READY = os.environ["AFFINITY_GDB_NETWORK_READY"]
BOOT_TIMEOUT = float(os.environ.get("AFFINITY_GDB_BOOT_TIMEOUT", "120"))

LABEL = "kernel/qemu affinity-rollover"
BUSY_STOPS = 2
RETRIED = (b"asid rollover: activation retried %d busy world stops, "
           b"then rolled over\n" % BUSY_STOPS)
# The boot reached the persistent shell after the injection was spent:
# every later exec activated too.
BOOT_DONE = b"interactive shell: uart blocked\n"
FAILED = b"oops: "

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
    # The ash lane's two handshakes, for the same network peer.
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


def main() -> None:
    deadline = time.monotonic() + BOOT_TIMEOUT
    # The UART is `wait=on`: QEMU starts when it is connected, and its gdb
    # stub answers from then on. Attaching stops the machine within
    # milliseconds, long before the boot's first stable activation, which
    # comes after its early fixtures.
    threading.Thread(target=reader, args=(connect(deadline),),
                     daemon=True).start()
    gdb.execute(f"target remote :{os.environ['AFFINITY_GDB_GDB_PORT']}")
    gdb.execute(f"set *(unsigned long *)&kernel_process_rollover_busy_injections = {BUSY_STOPS}")
    gdb.execute("detach")
    while time.monotonic() < deadline:
        with output_lock:
            text = bytes(output).replace(b"\r", b"")
        if FAILED in text:
            verdict(False, "an activation that met a Busy world stop "
                           "fail-stopped the kernel instead of retrying")
            return
        if RETRIED in text and BOOT_DONE in text.split(RETRIED, 1)[1]:
            verdict(True, f"an activation met {BUSY_STOPS} Busy world stops, "
                          "retried, rolled the ASID counter over, and the "
                          "boot finished")
            return
        time.sleep(0.1)
    if RETRIED not in bytes(output):
        verdict(False, "no activation reported the injected Busy world stops")
    else:
        verdict(False, "the boot did not reach the shell after the retry")


try:
    main()
except Exception as error:  # pylint: disable=broad-except
    verdict(False, f"check error: {error}")
