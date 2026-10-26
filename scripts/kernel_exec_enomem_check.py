"""Force real EL0 exec argv exhaustion and retry on both QEMU CPUs.

Run by the maintained affinity GDB runner in exec-enomem mode. Select the
caller by its register-only marker and exception-frame address, then refuse
only its ExecArgs allocation using compiler-owned variant return metadata.
No kernel injection switch, allocator corruption or MMIO read is needed.
"""

import json
import os
from pathlib import Path
import socket
import sys
import threading
import time

import gdb

sys.path.insert(0, str(Path(__file__).resolve().parent))
from await_timing import AwaitTiming  # noqa: E402
from gdb_progress import (DONE, QUIET, all_threads,  # noqa: E402
                          continue_by_ticks)
from progress_timeout import ProgressTimeout  # noqa: E402
from typed_marker import typed_marker  # noqa: E402

LABEL = "kernel/qemu exec-enomem"
UART_LOG = Path(os.environ["AFFINITY_GDB_UART_LOG"])
VERDICT = Path(os.environ["AFFINITY_GDB_VERDICT"])
BOOT_TIMEOUT = float(os.environ.get("AFFINITY_GDB_BOOT_TIMEOUT", "120"))
DEADLINE = time.monotonic() + float(os.environ.get("GDB_BATCH_TIMEOUT", "600")) - 10
SCRIPT_DIR = Path(__file__).resolve().parent
METADATA = SCRIPT_DIR.parent / "_build/kernel-debug-metadata.json"
ENOMEM = 0xFFFFFFFFFFFFFFF4
# GitHub issue #867: each step is reached within the ticks every vCPU takes
# (scripts/gdb_progress.py), about a minute of guest time at 64 Hz, the
# guest-time equivalent of the former 60 s; the batch ceiling caps host time.
STEP_TICKS = 64 * 60
output = bytearray()
output_lock = threading.Lock()


def reader(serial):
    serial.settimeout(0.2)
    with UART_LOG.open("wb") as log:
        while True:
            try:
                chunk = serial.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                return
            log.write(chunk)
            log.flush()
            with output_lock:
                output.extend(chunk.replace(b"\r", b""))
                text = bytes(output)
            for variable, marker in (
                ("AFFINITY_GDB_INIT_LISTENER", b"linux socket: listener ready port=8080\n"),
                ("AFFINITY_GDB_NETWORK_READY", b"virtio net: link ready "),
            ):
                if marker in text:
                    Path(os.environ[variable]).touch()


def text():
    with output_lock:
        return bytes(output)


def await_uart(predicate, phase):
    started = time.monotonic()
    ceiling = max(0, DEADLINE - started)
    timer = ProgressTimeout(BOOT_TIMEOUT, ceiling, started)
    timing = AwaitTiming(str(UART_LOG) + f".await-{phase}.jsonl", started,
                         ceiling, (), (), label=LABEL,
                         origin=f"remaining GDB batch ceiling (UART inactivity {BOOT_TIMEOUT:g}s)",
                         milestones=(phase,))
    previous_size = 0
    try:
        while not timer.expired(time.monotonic()):
            data = text()
            if len(data) > previous_size:
                timer.observe(time.monotonic())
                previous_size = len(data)
            if b"oops: " in data or b"exec-enomem: FAIL" in data:
                raise RuntimeError(f"{phase}: guest failure; UART tail {data[-300:]!r}")
            if predicate(data):
                timing.record(phase, True, time.monotonic())
                return
            time.sleep(0.05)
        raise RuntimeError(f"{phase}: no required UART evidence; tail {text()[-300:]!r}")
    finally:
        timing.finish(time.monotonic())


def register(name):
    return int(gdb.parse_and_eval("$" + name)) & 0xFFFFFFFFFFFFFFFF


def reach(breakpoint, phase):
    budget = max(0, DEADLINE - time.monotonic())
    if budget <= 0:
        raise RuntimeError(f"{phase}: GDB batch ceiling reached")
    threads = all_threads()
    outcome, ticks = continue_by_ticks(lambda: breakpoint.hit_count > 0,
                                       threads, STEP_TICKS,
                                       cap_seconds=budget)
    if outcome == DONE:
        return
    if outcome == QUIET:
        raise RuntimeError(f"{phase}: breakpoint was not reached within {ticks} "
                           f"ticks on every vCPU, pc={register('pc'):#x}")
    raise RuntimeError(f"{phase}: inconclusive, the guest stalled (a slice in "
                       "which some vCPU took no scheduler tick, or the host-time "
                       f"cap) before the breakpoint, pc={register('pc'):#x}")


def run():
    port = int(os.environ["AFFINITY_GDB_SERIAL_PORT"])
    serial = None
    until = min(DEADLINE, time.monotonic() + 30)
    while time.monotonic() < until:
        try:
            serial = socket.create_connection(("127.0.0.1", port), 1)
            break
        except OSError:
            time.sleep(0.05)
    if serial is None:
        raise RuntimeError("UART connection was not available")
    threading.Thread(target=reader, args=(serial,), daemon=True).start()
    await_uart(lambda data: b"interactive shell: uart blocked\n" in data, "first-shell")
    metadata = json.loads(METADATA.read_text())
    owner = next(item for item in metadata["enums"] if item["name"] == "PageOwnerTag")
    owner_tag = next(case["value"] for case in owner["cases"] if case["name"] == "ExecArgs")
    slot = next(item for item in metadata["variants"] if item["name"] == "Place$PageOwner")
    empty = next(case["tag"] for case in slot["cases"] if case["name"] == "Empty")
    gdb.execute("set pagination off")
    gdb.execute("set confirm off")
    gdb.execute(f"source {SCRIPT_DIR / 'kernel_debug_metadata.gdb'}")
    gdb.execute(f"takibi-debug-metadata {METADATA}")
    for cpu in (0, 1):
        queries = text().count(b"\x1b[6n")
        gdb.execute(f"target remote 127.0.0.1:{os.environ['AFFINITY_GDB_GDB_PORT']}")
        marker = gdb.Breakpoint("*kernel_syscall_dispatch")
        marker.condition = f"$x1 == 172 && $x2 == 0x700 && $x3 == {cpu}"
        # The complete command fits the PL011's 16-byte FIFO while stopped.
        serial.sendall(f"/bin/exenom{cpu}\n".encode("ascii"))
        reach(marker, f"cpu-{cpu}-marker")
        if gdb.selected_thread().global_num != cpu + 1:
            raise RuntimeError(f"cpu {cpu}: marker ran on the wrong vCPU")
        frame = register("x7")
        marker.delete()
        execute = gdb.Breakpoint("*kernel_syscall_dispatch")
        execute.condition = f"$x1 == 221 && $x7 == {frame} && $_thread == {cpu + 1}"
        reach(execute, f"cpu-{cpu}-execve")
        execute.delete()
        allocated = gdb.Breakpoint("page_alloc")
        allocated.thread = cpu + 1
        allocated.condition = f"(int)owner == {owner_tag}"
        reach(allocated, f"cpu-{cpu}-argv-allocation")
        allocated.delete()
        gdb.execute("takibi-force-variant-return PageAllocResult OutOfMemory")
        returned = gdb.Breakpoint("*kernel_syscall_resume_return")
        returned.condition = f"$x0 == {frame} && $_thread == {cpu + 1}"
        reach(returned, f"cpu-{cpu}-caller-return")
        returned.delete()
        if register("x1") != ENOMEM:
            raise RuntimeError(f"cpu {cpu}: execve did not return ENOMEM, value={register('x1'):#x}")
        # Read only the compiler-described tag in ordinary kernel RAM.
        address = int(gdb.parse_and_eval(f"&exec_args_store[{cpu}].value"))
        tag = bytes(gdb.selected_inferior().read_memory(address + slot["tag_offset"], slot["tag_size"]))  # gdb-memory-read: static kernel RAM in the shared kernel mapping; no user VA or MMIO.
        if int.from_bytes(tag, "little") != empty:
            raise RuntimeError(f"cpu {cpu}: refused exec left an owned argv page")
        print(f"exec-enomem: cpu={cpu} caller-return=ENOMEM slot=Empty", flush=True)
        gdb.execute("detach")
        kept = f"exec-enomem: cpu {cpu} returned ENOMEM and this image kept running\n".encode()
        replaced = f"exec-enomem: cpu {cpu} retry replaced the image\n".encode()
        await_uart(lambda data: kept in data and replaced in data and
                   data.count(b"\x1b[6n") > queries, f"cpu-{cpu}-preserved-and-retried")
    reserve_refused(serial)
    read_error_after_commit(serial)
    serial.close()


def exec_after_marker(serial, phase):
    """Start /bin/exenom0 on CPU 0 and stop at its execve's dispatch."""
    gdb.execute(f"target remote 127.0.0.1:{os.environ['AFFINITY_GDB_GDB_PORT']}")
    marker = gdb.Breakpoint("*kernel_syscall_dispatch")
    marker.condition = "$x1 == 172 && $x2 == 0x700 && $x3 == 0"
    serial.sendall(b"/bin/exenom0\n")
    reach(marker, f"{phase}-marker")
    if gdb.selected_thread().global_num != 1:
        raise RuntimeError(f"{phase}: marker ran on the wrong vCPU")
    frame = register("x7")
    marker.delete()
    execute = gdb.Breakpoint("*kernel_syscall_dispatch")
    execute.condition = f"$x1 == 221 && $x7 == {frame} && $_thread == 1"
    reach(execute, f"{phase}-execve")
    execute.delete()


def reserve_refused(serial):
    """GitHub issue #1079: the new image's page reservation, refused before
    the teardown, is ENOMEM to a caller that keeps running."""
    kept = b"exec-enomem: cpu 0 returned ENOMEM and this image kept running\n"
    replaced = b"exec-enomem: cpu 0 retry replaced the image\n"
    before = (text().count(kept), text().count(replaced))
    exec_after_marker(serial, "reserve")
    reserve = gdb.Breakpoint("page_reserve")
    reserve.thread = 1
    reach(reserve, "reserve-call")
    reserve.delete()
    gdb.execute("takibi-force-variant-return PageReserveResult Refused")
    print("exec-enomem: page reservation refused before the teardown", flush=True)
    gdb.execute("detach")
    await_uart(lambda data: data.count(kept) > before[0] and
               data.count(replaced) > before[1], "reserve-preserved-and-retried")


def read_error_after_commit(serial):
    """GitHub issue #1079: an image read error after the point of no return
    ends the process by SIGSEGV; the kernel and the shell run on."""
    kept = b"exec-enomem: cpu 0 returned ENOMEM and this image kept running\n"
    before = text().count(kept)
    exec_after_marker(serial, "read-error")
    mapped = gdb.Breakpoint("process_image_map_ext2_in_root")
    mapped.thread = 1
    reach(mapped, "read-error-map")
    mapped.delete()
    read = gdb.Breakpoint("ext2_read_file_chunk")
    read.thread = 1
    reach(read, "read-error-image-read")
    read.delete()
    gdb.execute("takibi-force-variant-return Ext2ReadResult Invalid")
    print("exec-enomem: image read refused after the teardown", flush=True)
    gdb.execute("detach")
    # The terminal holds the line until ash has reaped the child.
    serial.sendall(b"echo " + typed_marker(b"lost=") + b"$?\n")
    await_uart(lambda data: b"lost=139\n" in data, "read-error-sigsegv")
    if text().count(kept) != before:
        raise RuntimeError("read error: the caller ran on after its point of no return")


try:
    run()
    message = ("both CPUs returned ENOMEM with an empty handoff, preserved their EL0 image and placement, then completed an unforced exec; "
               "a refused page reservation was ENOMEM before the teardown (#1079); an image read error after it ended the caller by SIGSEGV (status 139) and the shell ran on")
    passed = True
except Exception as error:
    message = str(error)
    passed = False
finally:
    for breakpoint in gdb.breakpoints() or ():
        breakpoint.delete()
    try:
        gdb.execute("detach")
    except gdb.error:
        pass
line = f"{'PASS' if passed else 'FAIL'} {LABEL}: {message}"
print(line, flush=True)
VERDICT.write_text(line + "\n", encoding="ascii")
