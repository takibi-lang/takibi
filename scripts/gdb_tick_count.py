"""GitHub issue #867: guest progress read from the kernel's tick counters.

A `progress` measure for scripts/gdb_progress.py continue_by_ticks(), read
between slices without a breakpoint (see tick_count_progress()).
"""

import gdb


def tick_count_progress(threads):
    """A `progress` measure for continue_by_ticks() that reads the kernel's
    own per-core tick counters (secondary_tick_count, which core 0's tick
    also bumps) between slices instead of stopping the guest on every tick.

    GitHub issue #867: TickCounter's breakpoints stop all vCPUs on every
    tick of every listed core. Over the ddb lane's whole workload that
    perturbation left `ash wait` short of its background child (the uart
    lane hung after `busybox dmesg`), where the plain continue passed. A
    stage that resumes over a long stretch of workload, rather than a few
    ticks to a nearby breakpoint, uses this measure. gdb thread N is core
    N - 1 (QEMU numbers vCPUs from 1). The address arithmetic (one 8-byte
    AtomicWord per core) also works on an image without debug info.
    Returns the least ticks any listed core took since this call."""
    cores = tuple(number - 1 for number in threads)

    def read(core: int) -> int:
        return int(gdb.parse_and_eval(
            f"*(unsigned long *)((char *)&secondary_tick_count + {8 * core})"))

    start = {core: read(core) for core in cores}
    return lambda: min(read(core) - start[core] for core in cores)
