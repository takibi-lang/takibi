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
  or shows a wrong CPU is harmless (a diagnostic), and then relabels it.

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

# file -> (count, kind, reason)
LISTED = {
    "kernel/arch/arm64/boot/cpu.tkb": (7, FLIP, "not yet reviewed for migration"),
    "kernel/arch/arm64/kernel/exception_evidence.tkb": (9, FLIP, "not yet reviewed for migration"),
    "kernel/arch/arm64/kernel/secondary.tkb": (3, FLIP, "not yet reviewed for migration"),
    "kernel/arch/arm64/kernel/timer.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/drivers/block/memory.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/fs/ext2/mutation_lock.tkb": (2, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/console_contention_evidence.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/cpu_authority.tkb": (1, MINT, "the CpuHere mint itself"),
    "kernel/kernel/irq_counts.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/log_storm_evidence.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/nic_irq_affinity.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/pool_lock_wait.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/process.tkb": (40, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/profile_samples.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/profile_session.tkb": (4, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/profile_timeline.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/protocol_trace.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/stall_probe.tkb": (3, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/syscall.tkb": (5, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/uart_irq_affinity.tkb": (2, FLIP, "not yet reviewed for migration"),
    "kernel/kernel/workload_evidence.tkb": (46, FLIP, "not yet reviewed for migration"),
    "kernel/lib/diagnostic_ring.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/lib/occupancy.tkb": (6, FLIP, "not yet reviewed for migration"),
    "kernel/lib/peer_tick_window.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/mm/address_space.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/mm/process_image.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/net/tcp.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/platform/qemu/init.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/platform/rpi5/init.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/platform/rpi5/intc.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/platform/rpi5/xhci_irq_affinity.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/printk/console_lock.tkb": (1, FLIP, "not yet reviewed for migration"),
    "kernel/printk/log.tkb": (5, FLIP, "not yet reviewed for migration"),
    "kernel/printk/log_ring_trace.tkb": (3, FLIP, "not yet reviewed for migration"),
}


def counts_of(texts):
    found = {}
    for relative, text in texts.items():
        n = len(CALL.findall(code_only(text)))
        if n:
            found[relative] = n
    return found


def problems_of(texts, listed):
    found = counts_of(texts)
    problems = []
    for relative, n in sorted(found.items()):
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
        if relative not in found:
            problems.append(f"{relative}: listed but has no raw cpu_id() "
                            "call; remove its stale entry")
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
    return len(cases) + 2


def main():
    count = controls()
    texts = {}
    for path in sorted(KERNEL.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        texts[str(path.relative_to(ROOT))] = path.read_text()
    problems = problems_of(texts, LISTED)
    for relative, (n, kind, reason) in LISTED.items():
        if kind not in (MINT, FLIP) or not reason.strip() or n < 1:
            problems.append(f"{relative}: entry ({n}, {kind!r}, {reason!r}) is malformed")
    if problems:
        for problem in problems:
            print(f"ERROR raw-cpu-id-sites: {problem}")
        sys.exit(1)
    flip = sum(n for n, kind, _ in LISTED.values() if kind == FLIP)
    report_pass("raw-cpu-id-sites",
                f"{sum(n for n, _, _ in LISTED.values())} raw cpu_id() calls "
                f"in {len(LISTED)} files, {flip} on the #638 flip worklist; "
                f"{count} controls", files=len(texts))


if __name__ == "__main__":
    main()
