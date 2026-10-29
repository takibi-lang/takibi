# allcheck lane inventory

GitHub issue #908. Each QEMU lane costs a guest boot (often several) and adds
roughly its own time to every land, because allcheck is throughput bound
(#886: 34 lanes on 24 host threads, about 9000 lane-seconds).
`scripts/check_lane_budget.py` holds the number of leaf QEMU lanes at 25 and
the last allcheck's busy lane-seconds (elapsed less vCPU lease wait, #927) at 5900 (#1193, provisional); AGENTS.md says a new error-case
test joins an existing lane and a new lane needs the maintainer.

This page classifies every leaf lane so that a new case knows where to go and
so that the deterministic simulation (#909, lowest priority) knows what it
could take over. Seconds are from the 2026-10-23 allcheck in the main
checkout (`_build/lane-timing`, total 6825 s, QEMU 5598 s).

**Integration** lanes are evidence that only a real boot gives: the boot path,
MMU and exception entry, device models, real interrupt delivery, the debug
toolchain against a real ELF. They stay on QEMU/RPi5 whatever happens to #909.

**Error-case** lanes demonstrate a specific failure or race window: a fault
injected by GDB, a window widened by a source overlay, a reverted check that
must fail-stop. Their value is the interleaving or the refusal, not the
hardware, so a deterministic simulation could absorb them. Until it exists,
a new error case of the same kind is added to one of these lanes (a new
`WINDOWS` entry run by an existing race-window lane, one more alloc-rollback
point, one more GDB stop in affinity-gdb), not to a lane of its own.

| Lane | s | Class | What it proves |
|---|---:|---|---|
| kernelcheck-qemu-main | 335 | integration | boot, init, the ordinary QEMU suite end to end |
| kernelcheck-qemu-fdt-multibank | 102 | integration | boot with a multi-bank FDT memory map |
| kernelcheck-dma-qemu | 4 | integration | virtio-blk DMA fixture against the device model |
| kernelcheck-invariant-qemu | 1 | integration | kernel stop call sites resolved against the exact ELF |
| kernelcheck-qemu-debug-main | 97 | integration | the same suite on the DWARF debug kernel, lifecycle trace on from main (#965; 2026-10-24 back-to-back runs on 87 and 105 s, off 85, 92 and 136 s: inside host noise) |
| kernelcheck-gdb-helpers-qemu | 5 | integration | documented gdb helpers against a live debug kernel (#744) |
| kernelcheck-console-gdb-qemu | 165 | integration | crash/console layout read back with GDB |
| kernelcheck-churn-gdb-qemu | 235 | integration | process and ASID churn, MMU state read by GDB |
| kernelcheck-oops-qemu | 388 | integration | terminal fail-stop and read-only UART crash console |
| kernelcheck-ddb-qemu | 236 | integration | real PL011 BREAK enters DDB and `continue` resumes |
| kernelcheck-stack-overflow-qemu | 175 | integration | exception-entry stack guard at a real IRQ entry (#377) |
| kernelcheck-debug-return-abi-qemu | 2 | integration | debug sidecar variant return ABI, executed (#713) |
| kernelcheck-profile-qemu | 47 | integration | PMU sampling session end to end (#497) |
| kernelcheck-race-window-603-qemu | 388 | error-case | wait4 pending-block window, armed and reverted |
| kernelcheck-race-window-609-qemu | 350 | error-case | peer publishes Blocked in wait4 (#609) |
| kernelcheck-race-window-633-qemu | 425 | error-case | child exit vs parent record (#633) |
| kernelcheck-race-window-635-qemu | 164 | error-case | race window #635 reverted; #1211 RX-resume drain lost wake, armed and reverted (#1216) |
| kernelcheck-race-window-678-qemu | 330 | error-case | race window #678, armed and reverted |
| kernelcheck-race-window-705-qemu | 353 | error-case | removing ToIdle must be observed as failure (#705) |
| kernelcheck-race-window-761-qemu | 100 | error-case | connected read copying the wrong length must fail (#761) |
| kernelcheck-race-window-830-qemu | 136 | error-case | NIC fixture pinned to core 0 must fail (#830) |
| kernelcheck-probe-ticks-qemu | 499 | error-case | console contention window #651 and probe refusals |
| kernelcheck-uart-wake-qemu | 405 | error-case | UART and NetRx publication windows held by GDB (#546, #547, #587) |
| kernelcheck-affinity-gdb-qemu | 387 | error-case | migration gate (#9) and wait4 double walk (#571) under GDB |
| kernelcheck-alloc-rollback-qemu | 270 | error-case | each process-alloc acquisition fails once and rolls back (#414) |
| kernelcheck-rpi5 | 94 | integration (hardware) | the suite on the real board; outside the QEMU budget |

Totals: 13 integration QEMU lanes, 1792 s; 12 error-case lanes, 3807 s, which
is about 68 % of QEMU lane-seconds and the most a simulation could save.

Every lane whose runner hands QEMU a writable disk judges that disk after the
guest stops with `scripts/ext2_postcheck.py` (#1033: `e2fsck -fn`, free
counters against the bitmaps, known divergences), a few seconds inside the
lane rather than a lane of its own; `check_ext2_postcheck_lanes.py` refuses a
runner that skips it.

Caveats. An error-case lane boots a real kernel too, so it incidentally
re-proves boot; that is not why it exists, and qemu-main proves it. QEMU's
TCG does not model the weak memory ordering of the Cortex-A76, so none of
these lanes is memory-ordering evidence; that belongs to `make litmuscheck`
and the RPi5 lanes. Keep this table in step when a lane is added, removed or
merged.
