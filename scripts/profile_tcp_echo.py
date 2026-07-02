#!/usr/bin/env python3
"""
Rough execution profile of examples/tcp_echo/tcp_echo.tkb under QEMU, using
a sustained burst of large data segments (profile_tcp_burst_load.py)
instead of the request/response pattern profile_http_server.py used.

Why a second target example: profiling http_server.tkb found ~100% of
samples landing in its idle interrupt-wait loop (http_server.tkb:283),
because each HTTP request/response cycle is dominated by network round
trips and a deliberate 1s "confirm silence" correctness check -- the
server was idle almost the entire time, well below this sampler's ~75ms
resolution. tcp_echo.tkb sits one layer below HTTP, so profiling it with a
workload designed to keep it continuously busy (one connection, no
idle-provoking waits between segments, near-max-size payloads) is a
second, independent attempt at getting samples to land somewhere other
than the idle-wait loop -- see profile_tcp_burst_load.py's docstring for
exactly what's different about the workload this time.

Run as: python3 profile_tcp_echo.py path/to/kernel.debug.elf
(normally invoked via `make profile-tcp-echo`, which builds that -g kernel
first).

Same caveats as profile_http_server.py apply here unchanged (QEMU's TCG
emulation isn't cycle-accurate; each sample is a real halt/resume with its
own overhead) -- see that script's module docstring for the full
explanation. Not repeated here to avoid the two drifting out of sync;
if you're reading this file in isolation, go read that one too.
"""
import collections
import os
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
QEMU_HOST = "127.0.0.1"
QEMU_DGRAM_PORT = 17771   # must match tcp_echo_test.py's QEMU_PORT
LOCAL_DGRAM_PORT = 17772  # must match tcp_echo_test.py's LOCAL_PORT
GDB_PORT = 12361           # different from profile_http_server.py's, in case both are run close together
BOOT_WAIT_SECS = 1.5

NUM_SAMPLES = 300   # ~75ms each measured in this environment -> ~22s of sampling
# 1400-byte payloads, no idle-provoking waits between them, measured at
# ~51ms/segment round trip in this environment -> needs ~430 segments to
# cover the sampler's ~22s window; padded up so the burst doesn't finish
# early and let the tail of the sampling window fall back to idle.
NUM_SEGMENTS = 500

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
    if not addrs:
        return []
    proc = subprocess.run(
        ["addr2line", "-e", kernel_elf, "-f", "-C", "-a"],
        input="\n".join("0x%x" % a for a in addrs),
        capture_output=True, text=True, timeout=30,
    )
    lines = proc.stdout.splitlines()
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
        print("usage: profile_tcp_echo.py path/to/kernel.debug.elf", file=sys.stderr)
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
        print("Sampling (%d samples) while bursting %d TCP data segments..." %
              (NUM_SAMPLES, NUM_SEGMENTS), file=sys.stderr)

        load_proc = subprocess.Popen(
            [sys.executable, os.path.join(SCRIPT_DIR, "profile_tcp_burst_load.py"),
             str(NUM_SEGMENTS)],
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

    by_function = collections.Counter(func for func, _ in resolved)
    by_line = collections.Counter(fileline for _, fileline in resolved)

    print("\n%d samples resolved (of %d collected)" % (len(resolved), len(addrs)))
    print_table("Hottest functions", by_function, len(resolved))
    print_table("Hottest source lines", by_line, len(resolved))
    print("\nReminder: this is a relative/directional profile under QEMU's TCG "
          "emulation, not a real-hardware cycle count. See profile_http_server.py's "
          "module docstring for why.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
