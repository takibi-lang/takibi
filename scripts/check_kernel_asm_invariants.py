#!/usr/bin/env python3
# Static, hardware-free regression guard for two real bugs found on real
# RPi5 hardware in the same session (GitHub issues #229 and #231), both of
# which live in hand-written AArch64 assembly the .tkb type system cannot
# see into. Disassembles the already-built kernel.elf and checks the exact
# instruction-level invariant each bug's fix depends on, instead of relying
# on a human reviewer to remember a checklist (see AGENTS.md's "Every eret
# that returns to EL0 must mask DAIF.I..." entry) or on a probabilistic
# real-hardware race to reproduce. No board, no QEMU, no probabilistic
# timing -- this either finds the exact bytes or it doesn't.
#
# Deliberately does NOT add anything to the shipped kernel image itself
# (no new .S, no new .tkb): growing the hand-written-assembly surface to
# guard hand-written assembly was tried in this same session and rejected
# after the "robust" version of that idea (a PC-relative absolute-address
# lookup inside a payload that gets copied to a different execution
# address) was itself nearly shipped with a wrong address computation --
# a live demonstration of exactly the review burden this script exists to
# avoid growing further.
#
# Exit code only (0 = pass, 1 = fail); intended to run as part of
# `make kernelbuild-rpi5`, right after the ELF is linked.

import re
import subprocess
import sys

LLVM_OBJDUMP = "llvm-objdump-19"

# GitHub issue #231: kernel/arch/arm64/mm/mmu.tkb's init_root() (originally
# mmu.S's INIT_ROOT macro, textually duplicated once per root) is now one
# shared function, called twice (kernel_l1_0, kernel_l1_1 -- both cores'
# page-table roots) rather than compiled twice -- issue #226 preferred a
# real shared function over duplicated assembly, the same call #224 already
# made for kernel_mmu_activate. Its BODY writes the kernel .text identity
# block descriptor once (must carry UXN, bit 54, so EL0 can never fetch
# kernel .text) and the device-MMIO 1GB block descriptor twice, once per
# loop (64:65 and 124:127; must carry UXN+PXN, bits 54+53, since nothing
# should ever execute from device memory at either EL) -- 1 and 2
# occurrences respectively in the compiled function today (not 2 and 4:
# that would double-count what is now shared code, not two copies). Exact
# counts, not just "at least one", so silently dropping ONE of the two
# device-block sites (e.g. someone "simplifies" a loop and forgets the
# immediate) is caught too, not just losing both.
#
# Checked by reconstructing the full 64-bit value each `orr`/`movk`/`movz`
# instruction contributes, not by matching one specific instruction shape:
# issue #226 moved this construction from hand-written mmu.S (which always
# spelled it as a separate `mov`+`orr` because that assembly was written in
# two explicit steps) into .tkb, where `0x705 | UXN_BIT` is a compile-time
# constant expression the compiler is free to fold into a single `movk`-
# loaded literal instead -- an equally correct, equally intentional
# lowering choice that a check hardcoded to expect `orr` specifically would
# wrongly flag as a regression.
# GitHub issue #237 (QEMU port): the device-MMIO loop(s) moved out of
# init_root() itself into a per-platform platform_mmu_init_device_blocks()
# (kernel/platform/<target>/mmu_layout.tkb), since RPi5 and QEMU need
# different L1 index sets there (see that file's own header). The expected
# occurrence count is genuinely platform-specific -- RPi5 keeps its
# original two disjoint loops (64:65, 124:127), QEMU has one -- so it is
# now a required CLI argument instead of a hardcoded constant; each
# kernelbuild-<target> Makefile rule passes its own platform's count.
UXN_ONLY = 1 << 54
UXN_AND_PXN = (1 << 54) | (1 << 53)
EXPECTED_UXN_ONLY_COUNT = 1
DEVICE_BLOCK_FUNCTIONS = {"init_root", "platform_mmu_init_device_blocks"}

ORR_IMM_RE = re.compile(r"^orr\s+x\d+,\s*x\d+,\s*#(0x[0-9a-f]+)$")
MOV_IMM_SHIFT_RE = re.compile(
    r"^mov[kz]\s+x\d+,\s*#(0x[0-9a-f]+),\s*lsl\s*#(\d+)$")
MOV_IMM_RE = re.compile(r"^mov[kz]\s+x\d+,\s*#(0x[0-9a-f]+)$")


def contributed_bits(text):
    """The full 64-bit value this one instruction ORs/loads in, if any."""
    m = ORR_IMM_RE.match(text)
    if m:
        return int(m.group(1), 16)
    m = MOV_IMM_SHIFT_RE.match(text)
    if m:
        return int(m.group(1), 16) << int(m.group(2))
    m = MOV_IMM_RE.match(text)
    if m:
        return int(m.group(1), 16)
    return None

# GitHub issue #229: every eret that returns to EL0 (i.e. is preceded by a
# write to ELR_EL1/SPSR_EL1, as opposed to el2_drop_to_el1's one-time
# cold-boot ELR_EL2/SPSR_EL2 drop) must have DAIF.I masked somewhere in the
# instructions immediately before it. EXC_CONTEXT_RESTORE's own body
# (kernel/arch/arm64/kernel/exception_context.inc) is exactly 42
# instructions from its first `msr ELR_EL1` through the caller's own
# "add sp, ...; eret" tail (verified directly against the disassembly, not
# estimated -- an earlier ~35-instruction guess left this window a few
# instructions short and let a re-broken build through silently). 64 gives
# comfortable margin without reaching back far enough to false-pass on an
# unrelated DAIFClr/DAIFSet earlier in the same function (el0_sync_entry
# unmasks DAIF.I near its top for issue #187's reasons, then masks again at
# its own eret much later -- the window must not blur those two together).
# This is ALSO scoped to same-function instructions only (see
# check_eret_daif_mask below) for the same reason: two unrelated functions
# landing close together in the final linked .text must not let one
# function's DAIFSet credit a different function's eret.
DAIF_WINDOW = 64

INSN_RE = re.compile(r"^\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)$")
SYMBOL_RE = re.compile(r"^([0-9a-f]+) <([^>]+)>:$")


def objdump_lines(elf_path):
    out = subprocess.run(
        [LLVM_OBJDUMP, "-d", elf_path],
        check=True, capture_output=True, text=True,
    ).stdout
    return out.splitlines()


def parse_instructions(lines):
    """Returns a flat list of (address:int, mnemonic_line:str, function:str)."""
    insns = []
    current_fn = "?"
    for line in lines:
        m = SYMBOL_RE.match(line)
        if m:
            current_fn = m.group(2)
            continue
        m = INSN_RE.match(line)
        if m:
            addr = int(m.group(1), 16)
            insns.append((addr, m.group(2).strip(), current_fn))
    return insns


def check_uxn(insns, expected_uxn_and_pxn_count):
    failures = []
    # Scoped to init_root()/platform_mmu_init_device_blocks() specifically:
    # UXN+PXN together (0x60 << 48) is NOT a signature unique to the
    # device-MMIO block descriptors -- it is also exactly USER_RW_XN_FLAGS,
    # the ordinary read-write-execute-never permission bits kernel/mm/
    # address_space.tkb applies to every regular user data/heap/stack page,
    # so scanning the whole kernel.elf for that bit pattern finds it in a
    # dozen unrelated functions (map_user_data, map_user_stack,
    # user_page_writable, ...). Only these two functions' own instructions
    # are relevant to this check.
    root_insns = [(a, t) for a, t, fn in insns if fn == "init_root"]
    device_insns = [
        (a, t) for a, t, fn in insns if fn in DEVICE_BLOCK_FUNCTIONS
    ]
    bits = [contributed_bits(t) for _, t in root_insns]
    device_bits = [contributed_bits(t) for _, t in device_insns]
    count_uxn_only = sum(1 for b in bits if b == UXN_ONLY)
    count_uxn_and_pxn = sum(1 for b in device_bits if b == UXN_AND_PXN)
    if not root_insns:
        failures.append(
            "issue #231 regression: no instructions found in a function "
            "named 'init_root' -- kernel/arch/arm64/mm/mmu.tkb's page-table "
            "construction function was renamed or removed, and this check "
            "was not updated to match"
        )
    if not device_insns:
        failures.append(
            "issue #231/#237 regression: no instructions found in any of %s "
            "-- the device-MMIO block construction was renamed, removed, or "
            "moved to a differently-named function, and this check was not "
            "updated to match" % sorted(DEVICE_BLOCK_FUNCTIONS)
        )
    if count_uxn_only != EXPECTED_UXN_ONLY_COUNT:
        failures.append(
            "issue #231 regression: expected %d occurrence(s) of an "
            "instruction contributing the kernel identity block's UXN-only "
            "bit (0x%x) inside init_root(), found %d -- init_root()'s "
            "first descriptor (kernel .text, 0x705) must OR in UXN (bit 54)"
            % (EXPECTED_UXN_ONLY_COUNT, UXN_ONLY, count_uxn_only)
        )
    if count_uxn_and_pxn != expected_uxn_and_pxn_count:
        failures.append(
            "issue #231/#237 regression: expected %d occurrence(s) of an "
            "instruction contributing the device-MMIO block's UXN+PXN bits "
            "(0x%x) inside %s, found %d -- this platform's device block(s) "
            "(0x401 descriptors) must OR in UXN+PXN (bits 54+53)"
            % (expected_uxn_and_pxn_count, UXN_AND_PXN,
               sorted(DEVICE_BLOCK_FUNCTIONS), count_uxn_and_pxn)
        )
    return failures


def check_eret_daif_mask(insns):
    failures = []
    for i, (addr, text, fn) in enumerate(insns):
        if not text.startswith("eret"):
            continue
        # Scoped to same-function instructions only: two unrelated
        # functions laid out close together in the final linked .text (a
        # link-order accident, not a code relationship) must not let one
        # function's DAIFSet credit a completely different function's eret.
        # kernel_secondary_entry's own one-time cold-boot DAIFSet doing
        # exactly this to el1_current_irq_entry's eret, purely because the
        # two happened to land within DAIF_WINDOW raw instructions of each
        # other, is what caught this the first time this check was written.
        start = i
        while start > 0 and insns[start - 1][2] == fn:
            start -= 1
        start = max(start, i - DAIF_WINDOW)
        window = insns[start:i]
        has_elr_el1 = any(
            re.match(r"^msr\s+ELR_EL1,", t) for _, t, _ in window
        )
        if not has_elr_el1:
            # Not an EL0 return (e.g. el2_drop_to_el1's one-time cold-boot
            # ELR_EL2/SPSR_EL2 drop) -- DAIF.I masking is not this bug's
            # concern here.
            continue
        has_daifset = any(
            re.match(r"^msr\s+DAIFSet,", t) for _, t, _ in window
        )
        if not has_daifset:
            failures.append(
                "issue #229 regression: eret at 0x%x in %s() returns to EL0 "
                "(writes ELR_EL1) but no `msr DAIFSet` found in the "
                "preceding %d instructions -- an interrupt taken between "
                "the ELR_EL1/SPSR_EL1 writes and this eret can drop EL0 "
                "into kernel .text (see HISTORY.md's issue #229 entry and "
                "AGENTS.md's \"Every eret that returns to EL0...\" entry)"
                % (addr, fn, DAIF_WINDOW)
            )
    return failures



# GitHub issue #445: the pool lock has to be an ATOMIC, and reading the
# source is not evidence that it is one. Replacing the exchange in
# spin_trylock with a plain store leaves a lock that takes and releases
# correctly, passes a take/release smoke test, and excludes nothing --
# that exact substitution was made deliberately while writing
# linux_user/spinlock, and only the "a second attempt must fail" line
# caught it. This check catches the same substitution in the shipped
# kernel, where there is no second thread to notice.
#
# Two accepted forms rather than one instruction, because WHICH one is the
# backend's choice from --cpu and both are correct: ARMv8.0 (cortex-a53,
# QEMU virt) has no LSE and gets an ldaxr/stxr retry loop, while ARMv8.2
# (cortex-a76, RPi5) gets the single-instruction swpa. Pinning either one
# specifically would fail on the other target for no reason.
ATOMIC_EXCHANGE_RE = re.compile(r"^(swpa?l?|ldaxr|cas(a|l|al)?)\b")


def check_spinlock_is_atomic(insns):
    failures = []
    seen = {}
    for _, text, fn in insns:
        if fn in ("spin_trylock", "spin_unlock"):
            seen.setdefault(fn, []).append(text)

    body = seen.get("spin_trylock")
    if body is None:
        # Not an error on a build that does not link the lock at all; a
        # build that does and has lost the function is caught below by
        # spin_unlock, and a build with neither has no pool lock to guard.
        pass
    elif not any(ATOMIC_EXCHANGE_RE.match(t) for t in body):
        failures.append(
            "spin_trylock contains no atomic exchange (looked for swpa/ldaxr/"
            "cas): a lock that is a plain load and store excludes nothing, "
            "and passes every single-threaded test"
        )

    body = seen.get("spin_unlock")
    if body is not None and not any(t.startswith("stlr") for t in body):
        failures.append(
            "spin_unlock contains no stlr: releasing with a plain store lets "
            "the next holder observe this core's writes out of order, which "
            "is the ordering the lock exists to provide"
        )
    return failures



# GitHub issue #451/#449: mutex_acquire must MASK BEFORE IT TAKES.
#
# That order is the entire reason an interrupt handler may take one of
# these locks. Taking first leaves a window where this core holds the lock
# and an interrupt can arrive; a handler wanting the same lock then waits
# for a holder that cannot run until the handler returns, which is a hang
# rather than a delay. The source says so in a comment, and a comment is
# not what the CPU executes -- swapping two adjacent statements would
# compile, pass every single-core test, and hang the first time a handler
# contended.
def check_mutex_masks_before_taking(insns):
    failures = []
    body = [(addr, text) for addr, text, fn in insns if fn == "mutex_acquire"]
    if not body:
        # A build that does not link the lock has nothing to check.
        return failures
    mask_at = None
    take_at = None
    for addr, text in body:
        # Either the mask itself or the function that owns it. GitHub issue
        # #451 moved the DAIF pair behind the same substitution boundary
        # pool_lock lives on, so that a Mutex is host-compilable; the
        # ordering claim is unchanged and mutex_irq_save is checked below to
        # actually mask, so the indirection cannot hollow it out.
        if mask_at is None and ("<disable_irq>" in text
                                or "<mutex_irq_save>" in text):
            mask_at = addr
        if take_at is None and ("<spin_lock>" in text or "<spin_trylock>" in text):
            take_at = addr
    saver = [text for _, text, fn in insns if fn == "mutex_irq_save"]
    if saver and not any("<disable_irq>" in x or "DAIFSet" in x for x in saver):
        failures.append(
            "mutex_irq_save does not mask: mutex_acquire calls it where the "
            "interrupt mask is supposed to happen, so the ordering check "
            "below would be checking nothing"
        )
    if mask_at is None:
        failures.append(
            "mutex_acquire neither masks nor calls mutex_irq_save: a lock "
            "that does not mask cannot be taken from an interrupt handler "
            "without hanging against a holder on the same core"
        )
    elif take_at is None:
        failures.append(
            "mutex_acquire calls disable_irq but never spin_lock: it masks "
            "interrupts and takes nothing"
        )
    elif mask_at > take_at:
        failures.append(
            "mutex_acquire takes the lock at 0x%x before masking at 0x%x: "
            "an interrupt arriving in that window, in a handler wanting the "
            "same lock, waits for a holder that cannot run" % (take_at, mask_at)
        )
    return failures


# GitHub issue #446: the whole-TLB invalidate has to be the BROADCAST form.
#
# `tlbi vmalle1` and `tlbi vmalle1is` differ by two characters and by
# whether the other cores hear about it. The one that needs to broadcast is
# mmu_tlb_invalidate_all, which the ASID rollover calls: every live number
# is about to be handed to a different address space, so a core still
# holding entries tagged with the old ones reads another process's memory
# and takes no fault doing it. The one that must NOT is kernel_mmu_activate,
# where a core is discarding its own pre-MMU TLB and no other core has
# anything to discard.
#
# Checked here rather than by reading the source because the wrong one of
# the pair is correct on one core, and the failure it causes on two is
# silent. Source-level review has to notice a missing "is".
TLBI_VMALLE1_RE = re.compile(r"^tlbi\s+vmalle1$")
TLBI_VMALLE1IS_RE = re.compile(r"^tlbi\s+vmalle1is$")


def check_tlb_invalidate_all_is_broadcast(insns):
    failures = []
    seen = {}
    for _, text, fn in insns:
        if fn in ("mmu_tlb_invalidate_all", "kernel_mmu_activate"):
            seen.setdefault(fn, []).append(text)

    body = seen.get("mmu_tlb_invalidate_all")
    if body is None:
        failures.append(
            "mmu_tlb_invalidate_all is not in this image: the ASID rollover "
            "calls it, so a build without it has either lost the rollover or "
            "inlined the invalidate somewhere this check cannot see"
        )
    else:
        if not any(TLBI_VMALLE1IS_RE.match(t) for t in body):
            failures.append(
                "mmu_tlb_invalidate_all emits no `tlbi vmalle1is`: an ASID "
                "rollover that invalidates only the local TLB leaves another "
                "core translating with numbers that have just been reassigned"
            )
        if any(TLBI_VMALLE1_RE.match(t) for t in body):
            failures.append(
                "mmu_tlb_invalidate_all still emits the LOCAL `tlbi vmalle1`: "
                "the broadcast form replaced it, it did not join it"
            )

    body = seen.get("kernel_mmu_activate")
    if body is not None and not any(TLBI_VMALLE1_RE.match(t) for t in body):
        failures.append(
            "kernel_mmu_activate emits no LOCAL `tlbi vmalle1`: a core "
            "turning on its own MMU discards its own stale entries, and "
            "broadcasting that makes every core pay for one core's boot"
        )
    return failures


def main():
    if len(sys.argv) != 3:
        print(
            "usage: check_kernel_asm_invariants.py <kernel.elf> "
            "<expected_device_block_uxn_pxn_count>",
            file=sys.stderr,
        )
        return 1
    elf_path = sys.argv[1]
    expected_uxn_and_pxn_count = int(sys.argv[2])
    insns = parse_instructions(objdump_lines(elf_path))
    failures = (
        check_uxn(insns, expected_uxn_and_pxn_count)
        + check_eret_daif_mask(insns)
        + check_spinlock_is_atomic(insns)
        + check_mutex_masks_before_taking(insns)
        + check_tlb_invalidate_all_is_broadcast(insns)
    )
    if failures:
        for f in failures:
            print("FAIL kernel/asm-invariants: %s" % f, file=sys.stderr)
        return 1
    print("PASS kernel/asm-invariants: UXN identity-block bits, eret DAIF.I "
          "masking, the spinlock's atomicity, mutex_acquire masking "
          "before it takes, and the whole-TLB invalidate broadcasting "
          "while MMU activation stays local, all verified statically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
