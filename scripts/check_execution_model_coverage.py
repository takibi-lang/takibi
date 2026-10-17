#!/usr/bin/env python3
"""Every kernel file with mutable state must say what makes it safe.

kernel/lib/execution_model.tkb declares two numbers -- KERNEL_ACTIVE_CORES
and KERNEL_PREEMPTIBLE -- that most of this kernel's unsynchronized state is
safe BECAUSE OF, and nine files assert them so that raising either is a
build failure at each site rather than a silent change of meaning.

That file's own header names the hole this script fills:

    THE ASSERTION SET IS A CLAIM, NOT A PROOF. Nothing checks that every
    site depending on these numbers actually asserts them. [...] a new
    piece of unsynchronized shared state added without an assertion is
    exactly as invisible as it was before this file existed.

It was right, and twice in one day (2026-08-29/30) that invisibility cost
something. kernel/mm/page.tkb -- the page allocator, reached by every page
fault -- had no lock and no assertion and was not one of the ten sites
raising the constant reported; it was found by accident while fixing a
different file, and two cores on it produce 1618 double frees. Then
kernel/kernel/workload_evidence.tkb turned out to be the same, found the
same way.

So: a file that declares a mutable global must either name one of the two
constants, or appear in EXEMPT below with a reason. An entry there is a
claim a reviewer can disagree with, which is what silence was not.

Deliberately NOT a check that the assertion is CORRECT. Four assertion
messages went stale in one day by having their subject fixed underneath
them, and no cheap mechanical check for that exists -- the message is
prose. What this catches is the file that says nothing at all.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

KERNEL = pathlib.Path("kernel")
CONSTANTS = ("KERNEL_ACTIVE_CORES", "KERNEL_PREEMPTIBLE")
GLOBAL_RE = re.compile(r"^(?:private )?let mut ", re.M)

# path -> why this file's mutable state needs no execution-model assertion.
# Adding a name here is a claim. "Not audited" is a legitimate entry and is
# better than absence, because it is visible.
EXEMPT = {
    "kernel/stall_probe.tkb":
        "diagnostic words read by GDB at a stall, off in production "
        "(KERNEL_STALL_PROBES); a torn record is accepted (#665)",
    # --- Deliberately concurrent: these files ARE the two-core evidence,
    # and every shared word in them is an atomic. An assertion on the core
    # count would be backwards.
    "kernel/pool_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/freelist_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/page_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/asid_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/pid_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/schedule_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/occupancy_drain_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/pool_walk_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/ext2_mutation_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "lib/diagnostic_ring.tkb":
        "per-CPU rings published through GitHub issue #299's protocol; the "
        "commit word is an atomic and the reader re-checks it",
    "kernel/protocol_trace.tkb":
        "every write is made holding the process-run lock, and the report "
        "reads the buffer only after a hold has closed the window",
    "arch/arm64/kernel/secondary.tkb":
        "the secondary core's own entry point, which carries its own "
        "assertion in kernel_secondary_main",

    # --- Device state, single-core by interrupt routing rather than by a
    # number. Device SPIs are targeted at CPU0 (gicd_itargetsr8 =
    # 0x01010101), so the handler and the state it publishes stay on one
    # core by hardware configuration. GitHub issue #483 covers what a
    # syscall from a second core would reach.
    "drivers/net/virtio_net.tkb": "device state; SPIs are routed to CPU0",
    "drivers/net/virtio_net_tx_dma.tkb":
        "the packet pool's owner slots, exchanged under their own Mutexes, and "
        "the observation record and published address (GitHub issue #740)",
    "drivers/net/rp1_gem.tkb": "device state; MSI-X is routed to CPU0",
    "drivers/net/rp1_gem_desc.tkb":
        "the GEM descriptor rings' and packet buffers' owner slots, "
        "exchanged under their own Mutexes, and the observation records "
        "their lowerings read (GitHub issue #740)",
    "tests/qemu/dma/virtio_blk_fixture.tkb":
        "test-only entry boots no peers and keeps IRQs masked; independent of "
        "the production scheduler execution model",
    "drivers/block/virtio_blk.tkb":
        "device state; every command is issued under memory.tkb's "
        "block_device_lock (GitHub issue #533)",
    "drivers/block/virtio_blk_dma.tkb":
        "the receive allocation's owner slot and its mint functions, reached "
        "only from virtio_blk.tkb under block_device_lock (GitHub issue #716)",
    "drivers/virtio_used.tkb":
        "the virtio used rings' owner slots, exchanged under their own "
        "Mutexes, and the reset record its quiesces lowering reads (GitHub "
        "issue #740)",
    "drivers/block/memory.tkb":
        "GitHub issue #638: counters and read-ahead run are a slot pool handed "
        "out by compare-exchange under a linear BlockSlot, which holds for any "
        "core count and with preemption; the device is reached only under "
        "block_device_lock (GitHub issue #533)",
    "drivers/block/block_cache.tkb":
        "per-writer slots sized by KERNEL_MAX_CORES and indexed by the "
        "BlockSlot its only caller, memory.tkb, holds (GitHub issue #638, "
        "scripts/check_slot_pool_entries.py); another writer's writes arrive "
        "through the write epoch",
    "drivers/serial/uart_rx_ring.tkb":
        "the process-run lock serializes CPU 0's RX interrupt, termios "
        "line editing and terminal reads on any CPU",
    "platform/qemu/uart.tkb": "device state; SPIs are routed to CPU0",
    "arch/arm64/kernel/gicv2.tkb":
        "the GIC's IoHandles, attached on CPU0 during boot before secondaries start",
    "drivers/serial/pl011.tkb":
        "the console's IoHandle, attached on CPU0 during boot before secondaries start",
    "mm/memory_map.tkb":
        "the page allocator's LockedCell; every access holds its guard",
    "platform/rpi5/system_timer_dtb.tkb":
        "the system timer's IoHandle, attached and read once by CPU0's boot DTB check",
    "platform/qemu/device_map.tkb":
        "boot-time device discovery, written on CPU0 before secondaries start",
    "platform/qemu/timer_irq.tkb":
        "GIC device state is initialized before interrupts and used by its routed cores",
    "platform/rpi5/uart.tkb": "device state; MSI-X is routed to CPU0",
    "platform/rpi5/usb_provision.tkb":
        "the image and its copy buffers, used once by CPU0 while storage is "
        "set up, before any process exists",
    "platform/rpi5/pcie.tkb":
        "PCIe2 device state is initialized and used only by CPU0",
    "platform/rpi5/timer_irq.tkb":
        "GIC device state is initialized before interrupts and used by its routed cores",
    "platform/rpi5/usb_xhci_dma.tkb":
        "the receive allocations' owner slots and their mint functions, "
        "reached only from usb_xhci.tkb's commands (GitHub issue #716)",
    "platform/rpi5/usb_xhci_rings.tkb":
        "the producer rings' owner slots (each behind its own mutex) and "
        "the next doorbell/await parameters, reached only from "
        "usb_xhci.tkb's commands (GitHub issue #720)",
    "platform/rpi5/usb_xhci.tkb":
        "device state; MSI-X is routed to CPU0, and every mass-storage "
        "command after provisioning is issued under memory.tkb's "
        "block_device_lock (GitHub issue #533)",

    # --- Not state that depends on either number.
    "arch/arm64/mm/asid.tkb":
        "GitHub issue #452: the four numbers an assignment touches are a "
        "private field of a LockedCell, so an unguarded read is a compile "
        "error rather than a thing an assertion has to warn about; what is "
        "left (asid_bits, asid_last, asid_ready) is written once by "
        "asid_init in the MMU-off window, before PSCI has been asked for a "
        "second core",
    "kernel/irq_counts.tkb":
        "per-CPU rows are indexed below KERNEL_MAX_CORES; each is written "
        "only by its own CPU's IRQ dispatch and read by DDB under a world "
        "stop or by the boot fixture through one acquire load",
    "kernel/profile_samples.tkb":
        "per-CPU samples are indexed below KERNEL_MAX_CORES and opened or "
        "read only for kernel_online_core_count() under a world stop",
    "kernel/profile_session.tkb":
        "per-CPU buffers and counts are indexed below KERNEL_MAX_CORES; each "
        "is written by its own CPU's PMU interrupt or by DDB under a world "
        "stop, and the session mode is written only by DDB under a world stop",
    "kernel/profile_timeline.tkb":
        "per-CPU intervals are indexed below KERNEL_MAX_CORES and opened or "
        "read only for kernel_online_core_count() under a world stop",
    "kernel/workload_evidence.tkb":
        "per-CPU evidence is indexed below KERNEL_MAX_CORES and its shared "
        "profile snapshots use kernel_online_core_count() under a world stop",
    "fs/elf64.tkb":
        "ELF_IDENT_MAGIC is a lookup table that is never written; `let mut` "
        "is how this language declares an initialised array",
    "fs/ext2/ext2.tkb":
        "GitHub issue #638: the operation scratch is a slot pool handed out "
        "by compare-exchange under a linear Ext2Slot, which holds for any "
        "core count and with preemption; the fence words are written only by "
        "mutators, serialized by ext2_mutation_lock (which asserts the "
        "constant) or by the boot fixture before peers run",
    "fs/ext2/mutation_lock.tkb":
        "GitHub issue #533: the file's only mutable state IS the lock word, "
        "whose whole purpose is to hold whatever the core count becomes; an "
        "assertion on that count would be backwards",

    # --- Test-only state, reached from the boot fixture on core 0.
    "init/test_driver.tkb":
        "boot fixture state, driven from core 0's boot sequence only",
    "kernel/process_test_evidence.tkb":
        "test counters, read by the boot fixture only",
    "kernel/syscall_test_evidence.tkb":
        "test counters, read by the boot fixture only",
    "kernel/syscall_test_lifecycle.tkb":
        "test-driver lifecycle state, driven from core 0 only",
    "printk/console_lock.tkb":
        "the lock word serializes every transmit writer and protects the "
        "measurement counters and window flag, so no core count is assumed",
    "kernel/syscall_unimplemented.tkb":
        "every slot is claimed by an atomic compare-exchange and read by an "
        "atomic load, so no core count is assumed",
}


def main():
    if not KERNEL.is_dir():
        print("FAIL execution-model-coverage: kernel/ not found",
              file=sys.stderr)
        return 1

    stateful = []
    for path in sorted(KERNEL.rglob("*.tkb")):
        text = path.read_text()
        if GLOBAL_RE.search(text):
            stateful.append((path, text))

    if not stateful:
        print("FAIL execution-model-coverage: no file with mutable state "
              "found, which cannot be right", file=sys.stderr)
        return 1

    asserting = []
    exempt = []
    silent = []
    for path, text in stateful:
        rel = str(path.relative_to(KERNEL))
        if any(c in text for c in CONSTANTS):
            asserting.append(rel)
        elif rel in EXEMPT:
            exempt.append(rel)
        else:
            silent.append(rel)

    stale = [name for name in EXEMPT
             if not (KERNEL / name).exists()
             or not GLOBAL_RE.search((KERNEL / name).read_text())]

    failures = []
    for rel in silent:
        failures.append(
            "%s declares mutable state and names neither "
            "KERNEL_ACTIVE_CORES nor KERNEL_PREEMPTIBLE: state that is "
            "safe only because of one of those numbers must say so, or be "
            "listed in this script with the reason it does not need to"
            % rel)
    for name in stale:
        failures.append(
            "%s is exempted here but no longer has mutable state (or no "
            "longer exists): remove the entry rather than leaving a claim "
            "about nothing" % name)

    if failures:
        for f in failures:
            print("FAIL execution-model-coverage: %s" % f, file=sys.stderr)
        return 1

    not_audited = sum(1 for name in exempt
                      if EXEMPT[name].startswith("NOT AUDITED"))
    report_pass("execution-model-coverage",
                "%d files hold mutable state; %d assert an execution-model "
                "constant, %d are exempt with a stated reason (%d of those "
                "recorded as NOT AUDITED)"
                % (len(stateful), len(asserting), len(exempt), not_audited),
                stateful_files=len(stateful))
    return 0


if __name__ == "__main__":
    sys.exit(main())
