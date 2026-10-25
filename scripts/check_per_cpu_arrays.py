#!/usr/bin/env python3
"""Every per-CPU-sized kernel global has a reviewed form (#981).

A global `[T; KERNEL_MAX_CORES]` is one of three things:

- a per-CPU store: T is a `struct per_cpu`, and the compiler lets only the
  CpuHere a preempt_off block mints index it (#704, #638);
- a slot pool: per-operation state held across a call that may block,
  indexed by a linear slot token, never by the CPU (#638);
- an ordinary array that another CPU reads (a total, DDB, a probe, a boot
  handshake) or that waits on a decision. SPEC.md, "Per-CPU Storage": a
  cross-CPU read is not expressible on a per_cpu store, so these stay
  ordinary arrays, and each is listed below with its reader or its reason.

So a new `[T; KERNEL_MAX_CORES]` global indexed by cpu_id() -- the shape
#981 moved off, which silently aliased core 0 when an index helper fell back
to 0 -- cannot be added without choosing one of them here. A listed entry
whose global is gone, or whose type became per_cpu, is stale and refused.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

POOL = "pool"
CROSS = "cross-cpu"
PENDING = "pending"

# (file, global) -> (kind, reader or reason)
LISTED = {
    # Slot pools: indexed by a slot token's index, not by the CPU.
    ("kernel/fs/ext2/ext2.tkb", "ext2_scratch"): (POOL, "Ext2Slot"),
    ("kernel/fs/ext2/ext2.tkb", "ext2_slot_words"): (POOL, "Ext2Slot's acquire words"),
    ("kernel/drivers/block/memory.tkb", "block_slot_words"): (POOL, "BlockSlot's acquire words"),
    ("kernel/drivers/block/memory.tkb", "block_run_backend"): (POOL, "BlockSlot"),
    ("kernel/drivers/block/memory.tkb", "block_run_first"): (POOL, "BlockSlot"),
    ("kernel/drivers/block/memory.tkb", "block_run_count"): (POOL, "BlockSlot"),
    ("kernel/drivers/block/memory.tkb", "block_run_epoch"): (POOL, "BlockSlot"),
    ("kernel/drivers/block/memory.tkb", "block_run_next"): (POOL, "BlockSlot"),
    ("kernel/drivers/block/memory.tkb", "block_run_next_backend"): (POOL, "BlockSlot"),
    ("kernel/drivers/block/memory.tkb", "block_run_reads"): (POOL, "BlockSlot; totalled by the block report"),
    ("kernel/drivers/block/memory.tkb", "block_run_hits"): (POOL, "BlockSlot; totalled by the block report"),
    ("kernel/drivers/block/memory.tkb", "block_read_calls"): (POOL, "BlockSlot; totalled by the block report"),
    ("kernel/drivers/block/memory.tkb", "block_write_calls"): (POOL, "BlockSlot; totalled by the block report"),
    ("kernel/drivers/block/memory.tkb", "block_device_waits"): (POOL, "BlockSlot; totalled by the block report"),
    ("kernel/drivers/block/memory.tkb", "block_single_reads"): (POOL, "BlockSlot; totalled by the block report"),
    ("kernel/drivers/block/block_cache.tkb", "block_cache_tick"): (POOL, "BlockSlot's index"),
    ("kernel/drivers/block/block_cache.tkb", "block_cache_hits"): (POOL, "BlockSlot's index; totalled by the block report"),
    ("kernel/mm/process_image.tkb", "process_image_staging"): (POOL, "ProcessImageSlot"),
    ("kernel/mm/process_image.tkb", "process_image_slot_words"): (POOL, "ProcessImageSlot's acquire words"),
    ("kernel/kernel/syscall.tkb", "syscall_scratch"): (POOL, "SyscallSlot"),
    ("kernel/kernel/syscall.tkb", "syscall_slot_words"): (POOL, "SyscallSlot's acquire words"),
    ("kernel/init/test_driver.tkb", "exec_windows"): (POOL, "ExecWindowSlot"),
    ("kernel/init/test_driver.tkb", "exec_window_words"): (POOL, "ExecWindowSlot's acquire words"),
    # Read by another CPU.
    ("kernel/arch/arm64/kernel/exception_evidence.tkb", "crash_snapshot_per_core"): (CROSS, "DDB and the crash report on a stopped machine"),
    ("kernel/arch/arm64/kernel/exception_evidence.tkb", "crash_snapshot_capturing_per_core"): (CROSS, "DDB and the crash report on a stopped machine"),
    ("kernel/arch/arm64/kernel/exception_evidence.tkb", "kernel_ddb_memory_access"): (CROSS, "DDB's guarded read, armed for a stopped CPU"),
    ("kernel/arch/arm64/kernel/exception_evidence.tkb", "ddb_stopped_root"): (CROSS, "DDB walks every stopped CPU's root"),
    ("kernel/arch/arm64/kernel/secondary.tkb", "kernel_secondary_boot_state"): (CROSS, "the boot CPU's secondary handshake"),
    ("kernel/arch/arm64/kernel/secondary.tkb", "secondary_tick_count"): (CROSS, "peer tick waits and reports"),
    ("kernel/kernel/irq_counts.tkb", "irq_count_cores"): (CROSS, "DDB's intr view and the SGI fixture"),
    ("kernel/kernel/log_storm_evidence.tkb", "log_storm_last_round"): (CROSS, "the log-storm fixture's driver"),
    ("kernel/kernel/nic_irq_affinity.tkb", "nic_irq_taken"): (CROSS, "the NIC affinity report"),
    ("kernel/kernel/nic_irq_affinity.tkb", "nic_irq_phase_start"): (CROSS, "the NIC affinity report"),
    ("kernel/kernel/uart_irq_affinity.tkb", "uart_irq_taken"): (CROSS, "the UART affinity report"),
    ("kernel/platform/rpi5/xhci_irq_affinity.tkb", "xhci_irq_taken"): (CROSS, "the xHCI affinity report"),
    ("kernel/kernel/pid_contention_evidence.tkb", "pid_probe_done"): (CROSS, "the PID contention probe's driver"),
    ("kernel/kernel/pid_contention_evidence.tkb", "pid_probe_active"): (CROSS, "the PID contention probe's driver"),
    ("kernel/kernel/pool_lock_wait.tkb", "pool_lock_wait_cores"): (CROSS, "the pool-lock wait total"),
    ("kernel/kernel/process.tkb", "execution_state"): (CROSS, "the scheduler's cross-CPU wakes and DDB"),
    ("kernel/kernel/process.tkb", "kernel_activity"): (CROSS, "DDB's per-CPU activity view"),
    ("kernel/kernel/process.tkb", "kernel_crash_trace_next"): (CROSS, "the crash trace report"),
    ("kernel/kernel/process.tkb", "kernel_process_tick_wake_head"): (CROSS, "tick wakes posted by another CPU"),
    ("kernel/kernel/process.tkb", "kernel_process_tick_wake_due"): (CROSS, "tick wakes posted by another CPU"),
    ("kernel/kernel/process.tkb", "kernel_process_tick_wake_tick_now"): (CROSS, "the tick-wake report"),
    ("kernel/kernel/process.tkb", "kernel_process_tick_wake_tick_before"): (CROSS, "the tick-wake report"),
    ("kernel/kernel/profile_samples.tkb", "profile_sample_cores"): (CROSS, "the profile report"),
    ("kernel/kernel/profile_session.tkb", "profile_core_store"): (CROSS, "the profile session's collector"),
    ("kernel/kernel/profile_session.tkb", "profile_core_state"): (CROSS, "the profile session's collector"),
    ("kernel/kernel/profile_session.tkb", "irqsoff_core"): (CROSS, "the irqsoff report"),
    ("kernel/kernel/profile_session.tkb", "irqsoff_standing"): (CROSS, "the boot report's irqsoff lines (#958)"),
    ("kernel/kernel/profile_timeline.tkb", "profile_timeline_cores"): (CROSS, "the timeline report"),
    ("kernel/kernel/protocol_trace.tkb", "protocol_trace_cores"): (CROSS, "the protocol trace dump"),
    ("kernel/kernel/stall_probe.tkb", "stall_probe_last_tick"): (CROSS, "read from GDB by symbol name; the probe is off by default (KERNEL_STALL_PROBES)"),
    ("kernel/kernel/stall_probe.tkb", "stall_probe_idle_passes"): (CROSS, "read from GDB by symbol name; the probe is off by default (KERNEL_STALL_PROBES)"),
    ("kernel/kernel/stall_probe.tkb", "stall_probe_last_idle_pass"): (CROSS, "read from GDB by symbol name; the probe is off by default (KERNEL_STALL_PROBES)"),
    ("kernel/kernel/stall_probe.tkb", "stall_probe_last_wfi"): (CROSS, "read from GDB by symbol name; the probe is off by default (KERNEL_STALL_PROBES)"),
    ("kernel/kernel/stall_probe.tkb", "stall_probe_last_resume"): (CROSS, "read from GDB by symbol name; the probe is off by default (KERNEL_STALL_PROBES)"),
    ("kernel/kernel/stall_probe.tkb", "stall_probe_refusals"): (CROSS, "read from GDB by symbol name; the probe is off by default (KERNEL_STALL_PROBES)"),
    ("kernel/kernel/stall_probe.tkb", "stall_probe_last_refused_pid"): (CROSS, "read from GDB by symbol name; the probe is off by default (KERNEL_STALL_PROBES)"),
    ("kernel/kernel/tcp_connection_contention_evidence.tkb", "tcp_pool_cost_mailboxes"): (CROSS, "the pool-cost probe's driver"),
    ("kernel/kernel/workload_evidence.tkb", "workload_profile_cores"): (CROSS, "the workload profile report"),
    ("kernel/mm/address_space.tkb", "address_space_backing_missing_count"): (CROSS, "the missing-backing total"),
    ("kernel/mm/process_image.tkb", "process_image_record_missing_count"): (CROSS, "the missing-record total"),
    ("kernel/mm/process_image.tkb", "process_image_root_stale_count"): (CROSS, "the stale-root total"),
    ("kernel/net/tcp.tkb", "tcp_absent_fallback_count"): (CROSS, "the absent-fallback total"),
    ("kernel/printk/log.tkb", "kernel_log_snapshots"): (CROSS, "DDB's log snapshots (#613)"),
    ("kernel/printk/log.tkb", "kernel_log_core_state"): (CROSS, "the log ring's peers (#613)"),
    ("kernel/printk/log.tkb", "kernel_log_peer_console_probe_sent"): (CROSS, "the console probe's driver"),
    ("kernel/printk/log.tkb", "kernel_log_storm_found"): (CROSS, "the log-storm report"),
    ("kernel/printk/log_ring_trace.tkb", "log_ring_trace_cpus"): (CROSS, "the log ring trace dump"),
    # Own-CPU only, left an ordinary array by decision or for now.
    ("kernel/arch/arm64/boot/cpu.tkb", "irq_pmr_masked"): (PENDING, "PMR shadow: an out-of-range CPU must fall back to DAIF, not stop in the mint; revisited with #638, option 2 of #981"),
    ("kernel/arch/arm64/boot/cpu.tkb", "irq_pmr_ready"): (PENDING, "PMR shadow, as irq_pmr_masked"),
    ("kernel/printk/log.tkb", "kernel_log_peer_probe_emitted"): (PENDING, "log.tkb waits for #613"),
}

DECL = re.compile(
    r"^(?:private\s+)?(?:scratch\s+)?(?:region\s+)?let\s+mut\s+(\w+)\s*:\s*"
    r"\[\s*([A-Za-z_]\w*)\s*;\s*KERNEL_MAX_CORES\s*\]", re.M)
PER_CPU = re.compile(r"^\s*(?:private\s+)?struct\s+per_cpu\s+(\w+)", re.M)


def scan(texts):
    """{(file, global): element type} for top-level per-CPU-sized globals,
    and the set of per_cpu struct names."""
    found, per_cpu = {}, set()
    for relative, text in texts.items():
        code = code_only(text)
        # A declaration may break after its colon.
        joined = re.sub(r":\s*\n\s*\[", ": [", code)
        for match in DECL.finditer(joined):
            found[(relative, match.group(1))] = match.group(2)
        per_cpu.update(PER_CPU.findall(code))
    return found, per_cpu


def problems_of(texts, listed):
    found, per_cpu = scan(texts)
    problems = []
    for key, element in sorted(found.items()):
        if element in per_cpu:
            if key in listed:
                problems.append(f"{key[0]}: {key[1]} is a per_cpu store now; "
                                "remove its stale entry")
            continue
        if key not in listed:
            problems.append(
                f"{key[0]}: {key[1]} is a [{element}; KERNEL_MAX_CORES] "
                "global with no reviewed form: make it a struct per_cpu "
                "store, a slot pool, or list it with its cross-CPU reader")
    for key in sorted(listed):
        if key not in found:
            problems.append(f"{key[0]}: {key[1]} is listed but no longer "
                            "declared; remove its stale entry")
    return problems


def controls():
    """The check must refuse the shapes it exists to catch."""
    base = {"k/a.tkb": "struct per_cpu S { private x: usize; }\n"
                       "private let mut good: [S; KERNEL_MAX_CORES];\n"}
    if problems_of(base, {}):
        sys.exit("ERROR per-cpu-arrays: control: a per_cpu store was refused")
    cases = {
        "unlisted cpu_id array": (
            {"k/b.tkb": "private let mut bad: [usize; KERNEL_MAX_CORES];\n"}, {}),
        "declaration broken after its colon": (
            {"k/b.tkb": "private let mut bad:\n    [usize; KERNEL_MAX_CORES];\n"}, {}),
        "stale entry": ({}, {("k/c.tkb", "gone"): (CROSS, "x")}),
        "listed per_cpu store": (
            base, {("k/a.tkb", "good"): (CROSS, "x")}),
    }
    for label, (texts, listed) in cases.items():
        if not problems_of(texts, listed):
            sys.exit(f"ERROR per-cpu-arrays: control '{label}' was not refused")
    if problems_of({"k/d.tkb": "// let mut c: [usize; KERNEL_MAX_CORES];\n"}, {}):
        sys.exit("ERROR per-cpu-arrays: control: a comment was refused")
    if problems_of({"k/e.tkb": "fn f() {\n    let mut local: [usize; KERNEL_MAX_CORES];\n}\n"}, {}):
        sys.exit("ERROR per-cpu-arrays: control: a function local was refused")
    return len(cases) + 3


def main():
    count = controls()
    texts = {}
    for path in sorted(KERNEL.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        texts[str(path.relative_to(ROOT))] = path.read_text()
    problems = problems_of(texts, LISTED)
    for kind, reason in LISTED.values():
        if kind not in (POOL, CROSS, PENDING) or not reason.strip():
            problems.append(f"an entry has kind {kind!r} and reason {reason!r}")
    if problems:
        for problem in problems:
            print(f"ERROR per-cpu-arrays: {problem}")
        sys.exit(1)
    found, per_cpu = scan(texts)
    stores = sum(1 for element in found.values() if element in per_cpu)
    report_pass("per-cpu-arrays",
                f"every [T; KERNEL_MAX_CORES] global is a per_cpu store "
                f"({stores}), a slot pool, or listed with its cross-CPU "
                f"reader or reason ({len(LISTED)}); {count} controls",
                files=len(texts))


if __name__ == "__main__":
    main()
