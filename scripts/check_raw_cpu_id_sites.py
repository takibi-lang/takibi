#!/usr/bin/env python3
"""Every raw cpu_id() call in the kernel is counted per file (#638).

Under KERNEL_PREEMPTIBLE == 0 a task does not leave its CPU while it runs at
EL1, so `let core = cpu_id(); ... a[core] = ...` names the CPU the write runs
on. Once the kernel is preemptible that stops being true: a task preempted
between the read and the use can resume on another CPU and write that CPU's
slot from the wrong one. The preempt_off region (`preempt_off (cpu) {...}`,
kernel/kernel/cpu_authority.tkb) is the form that stays correct, because it
holds the CPU for its whole body; a raw cpu_id() outside it is an implicit
dependency on the constant that no static_assert names.

This check is the flip's inventory of those sites. Each file's count is
frozen with a kind:

- MINT: the authority's own file;
- FLIP: not yet reviewed; the flip moves the site into a region, shows it
  runs with IRQs masked or in interrupt context (where no switch happens),
  or shows a wrong CPU is harmless (a diagnostic), and then relabels it;
- REVIEWED_SITES, keyed by file and function (#1474): read before the flip,
  and each call holds under preemption for the reason the entry gives (#638
  stage 9). A count change in that function, or a call in another function
  of the file, is refused.

A new call, a removed call, or a file whose count changed without its entry
is refused, so the inventory stays current. It does not prove a site
correct; it keeps the worklist from growing unseen.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

MINT = "mint"
FLIP = "flip"

CALL = re.compile(r"\bcpu_id\s*\(\s*\)")

# file -> (count, kind, reason): the calls of a file outside REVIEWED_SITES.
LISTED = {
    "kernel/arch/arm64/kernel/exception_evidence.tkb": (9, FLIP, "not yet reviewed for migration"),
    "kernel/fs/ext2/mutation_lock.tkb": (2, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/cpu_authority.tkb": (2, MINT, "the CpuHere mint itself and its availability test (#638 stage 4)"),
    "kernel/kernel/process.tkb": (30, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/profile_session.tkb": (4, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/protocol_trace.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/stall_probe.tkb": (3, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/syscall.tkb": (5, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/workload_evidence.tkb": (29, FLIP, "not yet reviewed for migration"),
    "kernel/lib/occupancy.tkb": (6, FLIP, "not yet reviewed for migration"),
    "kernel/mm/page.tkb": (1, FLIP, "#1079 page_reserve_cpu: read only under the page pool's IRQ-masking lock, and the kernel is not preemptible (KERNEL_PREEMPTIBLE == 0), so the CPU cannot change before the lock is given back; page_alloc has no CpuHere to take"),
    "kernel/printk/log_ring_trace.tkb": (1, FLIP, "picks the buffer an event goes to; its slot is one fetch_add (#1159)"),
}

# "file::function" -> (count, reason): calls read before the flip that hold
# under preemption for the reason given (#638 stage 9, #1474). Keyed by
# function, so a new call in an already reviewed file is refused rather
# than absorbed by the file's label.
REVIEWED_SITES = {
    "kernel/kernel/workload_evidence.tkb::workload_busy_note_selected_locked": (5, "#638 stage 9: the function borrows the ProcessRunGuard (an IRQ-masking Mutex guard), so no tick switches the task while it reads and uses the CPU"),
    "kernel/kernel/workload_evidence.tkb::workload_busy_note_tick_locked": (1, "#638 stage 9: the function borrows the ProcessRunGuard (an IRQ-masking Mutex guard), so no tick switches the task while it reads and uses the CPU"),
    "kernel/kernel/workload_evidence.tkb::workload_busy_record_progress_locked": (8, "#638 stage 9: the function borrows the ProcessRunGuard (an IRQ-masking Mutex guard), so no tick switches the task while it reads and uses the CPU"),
    "kernel/kernel/workload_evidence.tkb::workload_profile_irq_enter": (1, "#638 stage 9: called only from the IRQ dispatch and irq_finish, !{interrupt} roots entered with IRQs masked"),
    "kernel/kernel/workload_evidence.tkb::workload_profile_irq_exit": (1, "#638 stage 9: called only from the IRQ dispatch and irq_finish, !{interrupt} roots entered with IRQs masked"),
    "kernel/kernel/workload_evidence.tkb::workload_profile_transition_masked": (1, "#638 stage 9: read after its own irq_save and used before the restore, so no tick switches the task in between"),
    "kernel/kernel/process.tkb::kernel_process_affinity_set": (1, "#638 stage 9: read while the process-run lock is held (an IRQ-masking Mutex guard), so no tick switches the task before the answer is used under that lock; the new mask is stored in the same hold, so a move after it can only resume the task on a CPU the new mask allows, where leaving again is a harmless reschedule"),
    "kernel/kernel/process.tkb::kernel_process_block_current": (1, "#638 stage 9: read while the process-run lock is held (an IRQ-masking Mutex guard), so no tick switches the task before the answer is used under that lock, inside the block tail's PreemptOff span (#1323)"),
    "kernel/kernel/process.tkb::kernel_process_child_exit": (3, "#638 stage 9: read while the process-run lock is held (an IRQ-masking Mutex guard), so no tick switches the task before the answer is used under that lock (exit_guard), inside the exit tail's span (#1323)"),
    "kernel/kernel/process.tkb::kernel_process_clone_unselectable_locked": (1, "#638 stage 9: read while the process-run lock is held (an IRQ-masking Mutex guard), so no tick switches the task before the answer is used under that lock"),
    "kernel/kernel/process.tkb::kernel_process_migrate_current": (2, "#638 stage 9: called only from kernel_syscall_migrate_return inside a PreemptOff span, and the second read is under the run lock"),
    "kernel/kernel/process.tkb::kernel_process_schedule": (1, "#638 stage 9: read while the process-run lock is held (an IRQ-masking Mutex guard), so no tick switches the task before the answer is used under that lock, inside the switch tail's PreemptOff span (#1323)"),
    "kernel/kernel/process.tkb::kernel_process_tick_leave_excluded": (1, "#638 stage 9: an !{interrupt} root, read under the run lock in the tick"),
    "kernel/kernel/process.tkb::kernel_process_tick_wake_if_due": (1, "#638 stage 9: an !{interrupt} root (the timer tick), entered with IRQs masked"),
    "kernel/kernel/process.tkb::scheduled_process_record_locked": (2, "#638 stage 9: read while the process-run lock is held (an IRQ-masking Mutex guard), so no tick switches the task before the answer is used under that lock (the function borrows the ProcessRunGuard; the CPU is a diagnostic word)"),
    "kernel/arch/arm64/kernel/secondary.tkb::kernel_idle_loop": (1, "#638 stage 9: kernel_tick_note runs from timer_irq_handler (interrupt context); kernel_secondary_main reads it during the secondary's PSCI bring-up, before it runs any task; kernel_idle_loop reads it on the idle stack, which has no current task, so the IRQ-return consult never switches it"),
    "kernel/arch/arm64/kernel/secondary.tkb::kernel_secondary_main": (1, "#638 stage 9: kernel_tick_note runs from timer_irq_handler (interrupt context); kernel_secondary_main reads it during the secondary's PSCI bring-up, before it runs any task; kernel_idle_loop reads it on the idle stack, which has no current task, so the IRQ-return consult never switches it"),
    "kernel/arch/arm64/kernel/secondary.tkb::kernel_tick_note": (1, "#638 stage 9: kernel_tick_note runs from timer_irq_handler (interrupt context); kernel_secondary_main reads it during the secondary's PSCI bring-up, before it runs any task; kernel_idle_loop reads it on the idle stack, which has no current task, so the IRQ-return consult never switches it"),
    "kernel/arch/arm64/kernel/timer.tkb::timer_irq_handler": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet, so no switch falls before the read's use: timer_irq_handler elects core 0's SEV"),
    "kernel/drivers/block/memory.tkb::block_slot_acquire": (1, "#638 stage 9: block_slot_acquire uses it only as the first slot to try; the slot is won by a compare-exchange, so a move makes the preference another CPU's and nothing else"),
    "kernel/kernel/console_contention_evidence.tkb::console_ddb_note_entry": (1, "#638 stage 9: console_ddb_note_entry runs from kernel_ddb_enter, an !{interrupt} root entered with IRQs masked, before the IRQ-return consult"),
    "kernel/kernel/irq_counts.tkb::irq_count_record": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet, so no switch falls before the read's use: irq_count_record, called from the GIC dispatch"),
    "kernel/kernel/log_storm_evidence.tkb::log_storm_secondary_run": (1, "#638 stage 9: log_storm_secondary_run runs only from kernel_idle_loop on a secondary, which has no current task, so the IRQ-return consult never switches it and the CPU it reads stays its own"),
    "kernel/kernel/nic_irq_affinity.tkb::nic_irq_handled": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet: nic_irq_handled, called by the platform dispatch before the EOI, counts the taking core"),
    "kernel/kernel/pool_lock_wait.tkb::pool_lock_wait_contended": (1, "#638 stage 9: picks the row a contended acquire is counted in; the add is atomic, so a move after the read only counts in another CPU's row (#1159), a diagnostic"),
    "kernel/kernel/profile_samples.tkb::profile_sample_irq": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet, so no switch falls before the read's use: profile_sample_irq, the PMU overflow handler"),
    "kernel/kernel/profile_timeline.tkb::profile_timeline_note": (1, "#638 stage 9: profile_timeline_note reads it after mutex_irq_save, with IRQs masked until its restore, so no tick switches the writer"),
    "kernel/kernel/uart_irq_affinity.tkb::uart_irq_hang_arm": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet: uart_irq_serve and uart_irq_hang_poll; and #980 uart_irq_hang_arm compares the target with the caller only to refuse a self-hang, and its EL0 caller (/lib/hang-core) is pinned to one CPU, so a move resumes it on that same CPU"),
    "kernel/kernel/uart_irq_affinity.tkb::uart_irq_hang_poll": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet: uart_irq_serve and uart_irq_hang_poll; and #980 uart_irq_hang_arm compares the target with the caller only to refuse a self-hang, and its EL0 caller (/lib/hang-core) is pinned to one CPU, so a move resumes it on that same CPU"),
    "kernel/kernel/uart_irq_affinity.tkb::uart_irq_serve": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet: uart_irq_serve and uart_irq_hang_poll; and #980 uart_irq_hang_arm compares the target with the caller only to refuse a self-hang, and its EL0 caller (/lib/hang-core) is pinned to one CPU, so a move resumes it on that same CPU"),
    "kernel/lib/diagnostic_ring.tkb::diagnostic_trace_record": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet, so no switch falls before the read's use: diagnostic_trace_record is !{interrupt}, so every caller holds IRQs masked (#641 D1)"),
    "kernel/lib/peer_tick_window.tkb::peer_tick_window_peer": (1, "#638 stage 9: peer_tick_window_peer's callers are the contention probes, run either by the boot thread from kernel_secondary_boot_report (its affinity mask names only core 0, #831, so a switch resumes it on core 0) or by a secondary's kernel_idle_loop (no current task, never switched)"),
    "kernel/platform/qemu/init.tkb::cpu_id": (1, "#638 stage 9: the definition of cpu_id() itself (the pattern matches its declaration), not a call"),
    "kernel/platform/rpi5/init.tkb::cpu_id": (1, "#638 stage 9: the definition of cpu_id() itself (the pattern matches its declaration), not a call"),
    "kernel/platform/rpi5/intc.tkb::gic_pmu_core_enable": (1, "#638 stage 9: gic_pmu_core_enable runs only in each core's bring-up (platform_irq_init on core 0, kernel_secondary_main on a peer), before that core runs any task"),
    "kernel/platform/rpi5/xhci_irq_affinity.tkb::xhci_irq_handled": (1, "#638 stage 9: read in interrupt context (an !{interrupt} root, entered with IRQs masked), where the IRQ-return consult has not run yet: xhci_irq_handled, called by the RPi5 dispatch before the EOI, counts the taking core"),
    "kernel/printk/console_lock.tkb::console_measure_note_acquire": (1, "#638 stage 9: console_measure_note_acquire reads it under a borrowed ConsoleGuard, an IRQ-masking Mutex guard, so no tick switches the holder before the CPU bit is recorded"),
    "kernel/printk/log.tkb::kernel_console_owner_word": (1, "#638 stage 9: kernel_log_core_here's writers run in preempt_off regions or boot probes; the reserve's CPU tag travels in its token; the console owner word is taken only on masked terminal or stopped-world paths; the peer probe runs in a secondary's idle loop (see the review comment in the file)"),
    "kernel/printk/log.tkb::kernel_log_core_here": (1, "#638 stage 9: kernel_log_core_here's writers run in preempt_off regions or boot probes; the reserve's CPU tag travels in its token; the console owner word is taken only on masked terminal or stopped-world paths; the peer probe runs in a secondary's idle loop (see the review comment in the file)"),
    "kernel/printk/log.tkb::kernel_log_peer_probe_step": (1, "#638 stage 9: kernel_log_core_here's writers run in preempt_off regions or boot probes; the reserve's CPU tag travels in its token; the console owner word is taken only on masked terminal or stopped-world paths; the peer probe runs in a secondary's idle loop (see the review comment in the file)"),
    "kernel/printk/log.tkb::kernel_log_reserve": (1, "#638 stage 9: kernel_log_core_here's writers run in preempt_off regions or boot probes; the reserve's CPU tag travels in its token; the console owner word is taken only on masked terminal or stopped-world paths; the peer probe runs in a secondary's idle loop (see the review comment in the file)"),
}

FN = re.compile(r"\bfn\s+(\w+)")


def per_function(text):
    """Raw calls of one file by the function whose `fn` precedes them."""
    code = code_only(text)
    starts = [(match.start(), match.group(1)) for match in FN.finditer(code)]
    found = {}
    for call in CALL.finditer(code):
        name = None
        for position, candidate in starts:
            if position > call.start():
                break
            name = candidate
        found[name] = found.get(name, 0) + 1
    return found


def counts_of(texts):
    found = {}
    for relative, text in texts.items():
        n = len(CALL.findall(code_only(text)))
        if n:
            found[relative] = n
    return found


def problems_of(texts, listed, reviewed=None):
    reviewed = reviewed or {}
    problems = []
    remainder = {}
    seen_sites = set()
    for relative, text in sorted(texts.items()):
        for function, n in sorted(per_function(code_only(text)).items(), key=lambda kv: str(kv[0])):
            site = f"{relative}::{function}"
            if site in reviewed:
                seen_sites.add(site)
                if reviewed[site][0] != n:
                    problems.append(
                        f"{site}: {n} raw cpu_id() call(s), reviewed as "
                        f"{reviewed[site][0]}: review the change and update the "
                        "entry (#638, #1474)")
            else:
                remainder[relative] = remainder.get(relative, 0) + n
    for relative, n in sorted(remainder.items()):
        if relative not in listed:
            problems.append(
                f"{relative}: {n} raw cpu_id() call(s) and no entry: use a "
                "preempt_off region, or list the file with its reason (#638)")
        elif listed[relative][0] != n:
            problems.append(
                f"{relative}: {n} raw cpu_id() call(s), listed as "
                f"{listed[relative][0]}: review the change and update the "
                "entry (#638)")
    for relative in sorted(listed):
        if relative not in remainder:
            problems.append(f"{relative}: listed but has no unreviewed raw "
                            "cpu_id() call; remove its stale entry")
    for site in sorted(reviewed):
        if site not in seen_sites:
            problems.append(f"{site}: reviewed but has no raw cpu_id() call; "
                            "remove its stale entry")
    return problems


def controls():
    """The check must refuse the shapes it exists to catch."""
    one = {"k/a.tkb": "fn f() -> usize { return cpu_id(); }\n"}
    good = {"k/a.tkb": (1, FLIP, "x")}
    if problems_of(one, good):
        sys.exit("ERROR raw-cpu-id-sites: control: a listed site was refused")
    cases = {
        "unlisted call": (one, {}),
        "count grew": ({"k/a.tkb": one["k/a.tkb"] + "fn g() { let c = cpu_id ( ); }\n"}, good),
        "stale entry": ({}, good),
    }
    for label, (texts, listed) in cases.items():
        if not problems_of(texts, listed):
            sys.exit(f"ERROR raw-cpu-id-sites: control '{label}' was not refused")
    if problems_of({"k/b.tkb": "// cpu_id()\n/* cpu_id() */\n"}, {}):
        sys.exit("ERROR raw-cpu-id-sites: control: a comment was refused")
    # #1474: a reviewed function is matched by name and count; a new call in
    # another function of the same file is not absorbed by the review.
    two = {"k/a.tkb": one["k/a.tkb"] + "fn g() -> usize { return cpu_id(); }\n"}
    seen = {"k/a.tkb::f": (1, "x")}
    if problems_of(one, {}, seen):
        sys.exit("ERROR raw-cpu-id-sites: control: a reviewed site was refused")
    reviewed_cases = {
        "new function in a reviewed file": (two, {}, seen),
        "reviewed function grew": ({"k/a.tkb": "fn f() -> usize { let a = cpu_id(); return cpu_id(); }\n"}, {}, seen),
        "stale reviewed site": ({}, {}, seen),
    }
    for label, (texts, listed, reviewed) in reviewed_cases.items():
        if not problems_of(texts, listed, reviewed):
            sys.exit(f"ERROR raw-cpu-id-sites: control '{label}' was not refused")
    return len(cases) + 3 + len(reviewed_cases)


def main():
    count = controls()
    texts = {}
    for path in sorted(KERNEL.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        texts[str(path.relative_to(ROOT))] = path.read_text()
    problems = problems_of(texts, LISTED, REVIEWED_SITES)
    for relative, (n, kind, reason) in LISTED.items():
        if kind not in (MINT, FLIP) or not reason.strip() or n < 1:
            problems.append(f"{relative}: entry ({n}, {kind!r}, {reason!r}) is malformed")
    for site, (n, reason) in REVIEWED_SITES.items():
        if "::" not in site or not reason.strip() or n < 1:
            problems.append(f"{site}: reviewed entry ({n}, {reason!r}) is malformed")
    if problems:
        for problem in problems:
            print(f"ERROR raw-cpu-id-sites: {problem}")
        sys.exit(1)
    flip = sum(n for n, kind, _ in LISTED.values() if kind == FLIP)
    reviewed = sum(n for n, _ in REVIEWED_SITES.values())
    report_pass("raw-cpu-id-sites",
                f"{sum(n for n, _, _ in LISTED.values()) + reviewed} raw cpu_id() "
                f"calls, {flip} on the #638 flip worklist, {reviewed} reviewed in "
                f"{len(REVIEWED_SITES)} functions; {count} controls",
                files=len(texts))


if __name__ == "__main__":
    main()
