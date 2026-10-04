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
from gdb_interrupt import interrupt_after  # noqa: E402
from progress_timeout import ProgressTimeout  # noqa: E402

LABEL = "kernel/qemu exec-enomem"
UART_LOG = Path(os.environ["AFFINITY_GDB_UART_LOG"])
VERDICT = Path(os.environ["AFFINITY_GDB_VERDICT"])
BOOT_TIMEOUT = float(os.environ.get("AFFINITY_GDB_BOOT_TIMEOUT", "120"))
DEADLINE = time.monotonic() + float(os.environ.get("GDB_BATCH_TIMEOUT", "600")) - 10
SCRIPT_DIR = Path(__file__).resolve().parent
METADATA = SCRIPT_DIR.parent / "_build/kernel-debug-metadata.json"
ENOMEM = 0xFFFFFFFFFFFFFFF4
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
    budget = min(60, max(0, DEADLINE - time.monotonic()))
    if budget <= 0:
        raise RuntimeError(f"{phase}: GDB batch ceiling reached")
    timer = interrupt_after(budget)
    try:
        gdb.execute("continue")
    except (gdb.error, KeyboardInterrupt):
        pass
    finally:
        timer.cancel()
    if breakpoint.hit_count == 0:
        raise RuntimeError(f"{phase}: breakpoint was not reached, pc={register('pc'):#x}")


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
    slot = next(item for item in metadata["variants"] if item["name"] == "ExecArgsValue")
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
    serial.close()


try:
    run()
    message = "both CPUs returned ENOMEM with an empty handoff, preserved their EL0 image and placement, then completed an unforced exec"
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
