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

# GitHub issue #231: kernel/arch/arm64/mm/mmu.S's INIT_ROOT macro is
# expanded twice (kernel_l1_0, kernel_l1_1 -- both cores' page-table
# roots). Each expansion writes the kernel .text identity block descriptor
# once (must carry UXN, bit 54, so EL0 can never fetch kernel .text) and
# the device-MMIO 1GB block descriptor twice, once per loop (64:65 and
# 124:127; must carry UXN+PXN, bits 54+53, since nothing should ever
# execute from device memory at either EL). That is 2 and 4 occurrences
# respectively in the linked kernel.elf today -- exact counts, not just
# "at least one", so silently dropping ONE of the four device-block sites
# (e.g. someone "simplifies" a loop and forgets the immediate) is caught
# too, not just losing all of them.
UXN_ONLY = 1 << 54
UXN_AND_PXN = (1 << 54) | (1 << 53)
EXPECTED_UXN_ONLY_COUNT = 2
EXPECTED_UXN_AND_PXN_COUNT = 4

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


def check_uxn(insns):
    failures = []
    count_uxn_only = sum(
        1 for _, text, _ in insns
        if re.match(r"^orr\s+x\d+,\s*x\d+,\s*#0x%x$" % UXN_ONLY, text)
    )
    count_uxn_and_pxn = sum(
        1 for _, text, _ in insns
        if re.match(r"^orr\s+x\d+,\s*x\d+,\s*#0x%x$" % UXN_AND_PXN, text)
    )
    if count_uxn_only != EXPECTED_UXN_ONLY_COUNT:
        failures.append(
            "issue #231 regression: expected %d occurrence(s) of the kernel "
            "identity block's UXN-only immediate (orr ..., #0x%x) in "
            "kernel_mmu_init, found %d -- mmu.S's INIT_ROOT macro's first "
            "descriptor (kernel .text, 0x705) must OR in UXN (bit 54)"
            % (EXPECTED_UXN_ONLY_COUNT, UXN_ONLY, count_uxn_only)
        )
    if count_uxn_and_pxn != EXPECTED_UXN_AND_PXN_COUNT:
        failures.append(
            "issue #231 regression: expected %d occurrence(s) of the "
            "device-MMIO block's UXN+PXN immediate (orr ..., #0x%x) in "
            "kernel_mmu_init, found %d -- mmu.S's INIT_ROOT macro's two "
            "device loops (0x401 descriptors) must OR in UXN+PXN (bits "
            "54+53)" % (EXPECTED_UXN_AND_PXN_COUNT, UXN_AND_PXN, count_uxn_and_pxn)
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


def main():
    if len(sys.argv) != 2:
        print("usage: check_kernel_asm_invariants.py <kernel.elf>", file=sys.stderr)
        return 1
    elf_path = sys.argv[1]
    insns = parse_instructions(objdump_lines(elf_path))
    failures = check_uxn(insns) + check_eret_daif_mask(insns)
    if failures:
        for f in failures:
            print("FAIL kernel/asm-invariants: %s" % f, file=sys.stderr)
        return 1
    print("PASS kernel/asm-invariants: UXN identity-block bits and "
          "eret DAIF.I masking both verified statically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
