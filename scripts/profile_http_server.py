#!/usr/bin/env python3
"""
Rough execution profile of examples/http_server/http_server.tkb under QEMU.

Run as: python3 profile_http_server.py path/to/kernel.debug.elf
(normally invoked via `make profile-http-server`, which builds that -g
kernel first).

What this does: launches QEMU (virtio-net over the same UDP-backed
-netdev dgram transport scripts/http_server_test.py uses) with its gdbstub
enabled, then runs two things concurrently against it --
  - profile_http_load.py: fires many HTTP requests so there's something
    to sample (http_server_test.py alone only sends 2, not enough for a
    profile -- see its own docstring).
  - profile_pc_sampler.py: repeatedly connects a fresh gdb-multiarch,
    reads $pc (connecting halts the vCPU; detaching resumes it), and
    disconnects -- the classic "poor man's profiler" technique, over
    QEMU's gdbstub instead of real silicon.
Once both finish, every sampled address is resolved to a function and
source line via `addr2line` against the kernel's own DWARF info (the -g
support added earlier in this project), aggregated, and printed as two
sorted tables: by function, and by source line.

READ THIS BEFORE TRUSTING THE NUMBERS:
  - QEMU's TCG emulation does not model real Cortex-A53 pipeline/cache/
    memory timing. This profile shows *relative* time spent per function/
    line under emulation, which is useful for spotting an obviously
    dominant hot path, but is not a stand-in for real hardware cycle
    counts. Two functions that look close in this profile could be
    ordered the other way around on real silicon.
  - Every sample here means literally halting the whole VM, reading a
    register, and resuming it (an "observer effect" -- see
    profile_pc_sampler.py's docstring). Each halt/resume has real overhead
    (~75ms measured in this environment), so this is a coarse, low
    sample-rate profile: good for "which function obviously dominates",
    not for finding a hot spot inside a function that only takes a few
    microseconds.
  - This technique (gdbstub PC sampling) is specific to this Cortex-A/
    AArch64 QEMU target. It does not carry over unchanged to a future
    STM32 (Cortex-M) port -- Cortex-M's usual equivalent is hardware
    ITM/DWT PC sampling over SWO, a completely different mechanism. See
    the project conversation history / CLAUDE.md for the fuller
    comparison of profiling techniques across QEMU and STM32.
"""
import os
import re
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
QEMU_HOST = "127.0.0.1"
QEMU_DGRAM_PORT = 17771   # must match http_server_test.py's QEMU_PORT
LOCAL_DGRAM_PORT = 17772  # must match http_server_test.py's LOCAL_PORT
GDB_PORT = 12360
BOOT_WAIT_SECS = 1.5

NUM_REQUESTS = 20   # ~1s+ each (do_request's trailing silence check) -> ~20-30s of load
NUM_SAMPLES = 300   # ~75ms each measured in this environment -> ~22s of sampling

VIRTIO_NET_ARGS = [
    "-global", "virtio-mmio.force-legacy=on",
    "-netdev", ("dgram,id=net0,local.type=inet,local.host=%s,local.port=%d,"
                "remote.type=inet,remote.host=%s,remote.port=%d")
               % (QEMU_HOST, QEMU_DGRAM_PORT, QEMU_HOST, LOCAL_DGRAM_PORT),
    "-device", ("virtio-net-device,netdev=net0,mac=52:54:00:12:34:56,csum=off,"
                "guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,"
                "guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,"
                "indirect_desc=off,event_idx=off"),
]


def resolve_samples(kernel_elf: str, addrs: list):
    """addr2line -f -C -a, fed all addresses at once via stdin (one process,
    not one per address -- addr2line's own startup cost would otherwise
    dominate for a few hundred samples)."""
    if not addrs:
        return []
    proc = subprocess.run(
        ["addr2line", "-e", kernel_elf, "-f", "-C", "-a"],
        input="\n".join("0x%x" % a for a in addrs),
        capture_output=True, text=True, timeout=30,
    )
    lines = proc.stdout.splitlines()
    # -a prints 3 lines per address: the address, the function, the file:line.
    resolved = []
    for i in range(0, len(lines) - 2, 3):
        _addr, func, fileline = lines[i], lines[i + 1], lines[i + 2]
        resolved.append((func, fileline))
    return resolved


def print_table(title: str, counter, total: int):
    print("\n%s\n%s" % (title, "-" * len(title)))
    for key, count in counter.most_common(15):
        pct = 100.0 * count / total if total else 0.0
        print("  %5d  %5.1f%%  %s" % (count, pct, key))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: profile_http_server.py path/to/kernel.debug.elf", file=sys.stderr)
        return 1
    kernel_elf = sys.argv[1]

    qemu = subprocess.Popen(
        ["qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a53", "-nographic",
         "-semihosting-config", "enable=on,target=native",
         *VIRTIO_NET_ARGS,
         "-gdb", "tcp::%d" % GDB_PORT,
         "-kernel", kernel_elf],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        print("Booting QEMU (pid %d)..." % qemu.pid, file=sys.stderr)
        time.sleep(BOOT_WAIT_SECS)

        samples_file = "/tmp/takibi_profile_samples_%d.txt" % os.getpid()
        print("Sampling (%d samples) while sending %d HTTP requests..." %
              (NUM_SAMPLES, NUM_REQUESTS), file=sys.stderr)

        load_proc = subprocess.Popen(
            [sys.executable, os.path.join(SCRIPT_DIR, "profile_http_load.py"),
             str(NUM_REQUESTS)],
        )
        sampler_proc = subprocess.Popen(
            [sys.executable, os.path.join(SCRIPT_DIR, "profile_pc_sampler.py"),
             str(GDB_PORT), samples_file, str(NUM_SAMPLES)],
        )

        sampler_proc.wait(timeout=120)
        load_proc.wait(timeout=120)
    finally:
        qemu.terminate()
        try:
            qemu.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qemu.kill()

    with open(samples_file) as f:
        addrs = [int(line.strip(), 16) for line in f if line.strip()]
    os.remove(samples_file)

    if not addrs:
        print("No samples collected -- nothing to report.", file=sys.stderr)
        return 1

    resolved = resolve_samples(kernel_elf, addrs)

    import collections
    by_function = collections.Counter(func for func, _ in resolved)
    by_line = collections.Counter(fileline for _, fileline in resolved)

    print("\n%d samples resolved (of %d collected)" % (len(resolved), len(addrs)))
    print_table("Hottest functions", by_function, len(resolved))
    print_table("Hottest source lines", by_line, len(resolved))
    print("\nReminder: this is a relative/directional profile under QEMU's TCG "
          "emulation, not a real-hardware cycle count. See this script's module "
          "docstring for why.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
