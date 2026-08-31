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

KERNEL = pathlib.Path("kernel")
CONSTANTS = ("KERNEL_ACTIVE_CORES", "KERNEL_PREEMPTIBLE")
GLOBAL_RE = re.compile(r"^(?:private )?let mut ", re.M)

# path -> why this file's mutable state needs no execution-model assertion.
# Adding a name here is a claim. "Not audited" is a legitimate entry and is
# better than absence, because it is visible.
EXEMPT = {
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
    "kernel/tag_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "kernel/schedule_contention_evidence.tkb":
        "the two-core probes; every shared word is an atomic by design",
    "lib/diagnostic_ring.tkb":
        "per-CPU rings published through GitHub issue #299's protocol; the "
        "commit word is an atomic and the reader re-checks it",
    "arch/arm64/kernel/secondary.tkb":
        "the secondary core's own entry point, which carries its own "
        "assertion in kernel_secondary_main",

    # --- Device state, single-core by interrupt routing rather than by a
    # number. Device SPIs are targeted at CPU0 (gicd_itargetsr8 =
    # 0x01010101), so the handler and the state it publishes stay on one
    # core by hardware configuration. GitHub issue #483 covers what a
    # syscall from a second core would reach.
    "drivers/net/virtio_net.tkb": "device state; SPIs are routed to CPU0",
    "drivers/net/rp1_gem.tkb": "device state; MSI-X is routed to CPU0",
    "drivers/block/virtio_blk.tkb": "device state; SPIs are routed to CPU0",
    "drivers/block/memory.tkb": "device state; SPIs are routed to CPU0",
    "platform/qemu/uart.tkb": "device state; SPIs are routed to CPU0",
    "platform/qemu/timer_irq.tkb":
        "GIC device state is initialized before interrupts and used by its routed cores",
    "platform/rpi5/uart.tkb": "device state; MSI-X is routed to CPU0",
    "platform/rpi5/pcie.tkb":
        "PCIe2 device state is initialized and used only by CPU0",
    "platform/rpi5/timer_irq.tkb":
        "GIC device state is initialized before interrupts and used by its routed cores",
    "platform/rpi5/usb_xhci.tkb": "device state; MSI-X is routed to CPU0",

    # --- Not state that depends on either number.
    "arch/arm64/mm/asid.tkb":
        "GitHub issue #452: the four numbers an assignment touches are a "
        "private field of a LockedCell, so an unguarded read is a compile "
        "error rather than a thing an assertion has to warn about; what is "
        "left (asid_bits, asid_last, asid_ready) is written once by "
        "asid_init in the MMU-off window, before PSCI has been asked for a "
        "second core",
    "fs/elf64.tkb":
        "ELF_IDENT_MAGIC is a lookup table that is never written; `let mut` "
        "is how this language declares an initialised array",

    # --- Test-only state, reached from the boot fixture on core 0.
    "init/test_driver.tkb":
        "boot fixture state, driven from core 0's boot sequence only",
    "kernel/process_test_evidence.tkb":
        "test counters, read by the boot fixture only",
    "kernel/syscall_test_evidence.tkb":
        "test counters, read by the boot fixture only",
    "kernel/syscall_test_lifecycle.tkb":
        "test-driver lifecycle state, driven from core 0 only",
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
    print("PASS execution-model-coverage: %d files hold mutable state; %d "
          "assert an execution-model constant, %d are exempt with a stated "
          "reason (%d of those recorded as NOT AUDITED)"
          % (len(stateful), len(asserting), len(exempt), not_audited))
    return 0


if __name__ == "__main__":
    sys.exit(main())
