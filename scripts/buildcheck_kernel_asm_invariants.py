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

import os
import re
import subprocess
import sys

from pass_line import report_pass

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
# GitHub issue #1032: the kernel identity is no longer one init_root block
# but a shared L2/L3 pair built by this function. Its text pages carry UXN
# only (0x787, read-only, EL1-executable); every other block and page
# carries UXN+PXN. One constant of each, as built today.
# GitHub issue #1032 point 5: the L3 pages are filled by one helper,
# mmu_init_identity_l3, for the text block and the stack blocks alike.
KERNEL_IDENTITY_FUNCTIONS = {"mmu_init_kernel_identity_tables", "mmu_init_identity_l3"}
KERNEL_IDENTITY_FUNCTION = "mmu_init_kernel_identity_tables or mmu_init_identity_l3"
# Two since #1032 point 5: the 2 MiB blocks in one function, the 4 KiB
# pages in the L3 helper.
EXPECTED_IDENTITY_UXN_AND_PXN_COUNT = 2
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
    root_insns = [(a, t) for a, t, fn in insns
                  if fn in KERNEL_IDENTITY_FUNCTIONS]
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
            "named '%s' -- kernel/arch/arm64/mm/mmu.tkb's page-table "
            "construction function was renamed or removed, and this check "
            "was not updated to match" % KERNEL_IDENTITY_FUNCTION
        )
    if not device_insns:
        failures.append(
            "issue #231/#237 regression: no instructions found in any of %s "
            "-- the device-MMIO block construction was renamed, removed, or "
            "moved to a differently-named function, and this check was not "
            "updated to match" % sorted(DEVICE_BLOCK_FUNCTIONS)
        )
    count_identity_xn = sum(1 for b in bits if b == UXN_AND_PXN)
    if root_insns and count_identity_xn != EXPECTED_IDENTITY_UXN_AND_PXN_COUNT:
        failures.append(
            "issue #1032 regression: expected %d occurrence(s) of the "
            "UXN+PXN bits (0x%x) inside %s, found %d -- the kernel "
            "identity's data blocks and pages must be execute-never at both "
            "ELs" % (EXPECTED_IDENTITY_UXN_AND_PXN_COUNT, UXN_AND_PXN,
                     KERNEL_IDENTITY_FUNCTION, count_identity_xn)
        )
    if count_uxn_only != EXPECTED_UXN_ONLY_COUNT:
        failures.append(
            "issue #231 regression: expected %d occurrence(s) of an "
            "instruction contributing the kernel identity block's UXN-only "
            "bit (0x%x) inside %s(), found %d -- the kernel text pages "
            "(0x787) must OR in UXN (bit 54)"
            % (EXPECTED_UXN_ONLY_COUNT, UXN_ONLY, KERNEL_IDENTITY_FUNCTION,
               count_uxn_only)
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



# GitHub issues #445/#450: the pool lock has to be ATOMIC, and reading the
# source is not evidence that it is one. Replacing compare-exchange in
# spin_trylock with a plain store leaves a lock that takes and releases
# correctly, passes a take/release smoke test, and excludes nothing --
# that exact substitution was made deliberately while writing
# linux_user/spinlock, and only the "a second attempt must fail" line
# caught it. This check catches the same substitution in the shipped
# kernel, where there is no second thread to notice.
#
# Two accepted forms rather than one instruction, because WHICH one is the
# backend's choice from --cpu and both are required: ARMv8.0 (cortex-a53,
# QEMU virt) has no LSE and gets ldaxr/stxr, while ARMv8.2 (cortex-a76,
# RPi5) gets the single-instruction casa. This is also the round-trip test
# for the project-local LLVMBuildAtomicCmpXchg OCaml bridge.


def check_spinlock_is_atomic(insns, elf_path):
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
    elif "qemu" in elf_path:
        if not any(t.startswith("ldaxr") for t in body) or not any(
                t.startswith("stxr") for t in body):
            failures.append(
                "QEMU spin_trylock is not the cortex-a53 ldaxr/stxr "
                "compare-exchange loop"
            )
    elif "rpi5" in elf_path and not any(t.startswith("casa") for t in body):
        failures.append(
            "RPi5 spin_trylock is not the cortex-a76 casa selected by LLVM"
        )

    body = seen.get("spin_unlock")
    if body is not None and not any(t.startswith("stlr") for t in body):
        failures.append(
            "spin_unlock contains no stlr: releasing with a plain store lets "
            "the next holder observe this core's writes out of order, which "
            "is the ordering the lock exists to provide"
        )
    return failures


# GitHub issue #480: Takibi's AArch64 backend permits LLVM to combine
# naturally aligned scalar accesses into pair/vector instructions. That is
# valid for the kernel's Normal memory only while SCTLR_EL1.A is clear. The
# pre-MMU Device-memory window is stricter regardless of A and retains exact
# object-alignment guards; this check pins the other half of the contract so a
# future boot edit cannot enable alignment checking underneath unchanged
# generated code.
SCTLR_WRITE_RE = re.compile(r"^msr\s+SCTLR_EL1,\s*x(\d+)$")
AND_IMM_RE = re.compile(
    r"^and\s+[wx](\d+),\s*[wx]\d+,\s*#(0x[0-9a-f]+|\d+)$")
BIC_IMM_RE = re.compile(
    r"^bic\s+[wx](\d+),\s*[wx]\d+,\s*#(0x[0-9a-f]+|\d+)$")
DEST_REG_RE = re.compile(r"^[a-z0-9.]+\s+[wx](\d+)(?:,|$)")
NO_GPR_DEST_RE = re.compile(
    r"^(?:b(?:\.[a-z]+)?|bl|br|blr|cbnz|cbz|cmp|cmn|ret|str|stp|stlr|"
    r"stlxr|stur|tbz|tbnz|msr)\b"
)


AND_REG_RE = re.compile(r"^and\s+[wx](\d+),\s*[wx]\d+,\s*[wx](\d+)$")


def register_constants(texts):
    """Each register's constant as mov/movk build it, in program order."""
    consts = {}
    for text in texts:
        text = text.split("//")[0].strip()
        m = CONST_MOV_RE.match(text)
        if m:
            consts[m.group(1)] = (int(m.group(2), 0)
                                  << int(m.group(3) or 0)) & (2**64 - 1)
            continue
        m = CONST_MOVK_RE.match(text)
        if m:
            shift = int(m.group(3) or 0)
            old = consts.get(m.group(1), 0) & ~(0xFFFF << shift)
            consts[m.group(1)] = old | (int(m.group(2), 0) << shift)
    return consts


def sctlr_and_mask(body, write_index, target_reg, producer):
    """The AND mask the SCTLR_EL1 write's value last went through, or None.

    An AND immediate, a BIC immediate (as its complement), or, since
    #1032 clears two non-adjacent bits that no logical immediate encodes,
    an AND with a register whose constant mov/movk built earlier.
    """
    if producer is None:
        return None
    producer = producer.split("//")[0].strip()
    match_and = AND_IMM_RE.match(producer)
    if match_and and match_and.group(1) == target_reg:
        return int(match_and.group(2), 0)
    match_bic = BIC_IMM_RE.match(producer)
    if match_bic and match_bic.group(1) == target_reg:
        return ~int(match_bic.group(2), 0) & (2**64 - 1)
    match_reg = AND_REG_RE.match(producer)
    if match_reg and match_reg.group(1) == target_reg:
        consts = register_constants(text for _, text in body[:write_index])
        if match_reg.group(2) in consts:
            return consts[match_reg.group(2)]
    return None


def check_sctlr_allows_normal_memory_unaligned_access(insns):
    failures = []
    body = [(addr, text) for addr, text, fn in insns
            if fn == "kernel_mmu_activate"]
    if not body:
        return [
            "issue #480 regression: no kernel_mmu_activate instructions "
            "found, so the SCTLR_EL1.A alignment policy is unverified"
        ]

    writes = [(i, addr, text, SCTLR_WRITE_RE.match(text))
              for i, (addr, text) in enumerate(body)
              if SCTLR_WRITE_RE.match(text)]
    if len(writes) != 1:
        return [
            "issue #480 regression: expected exactly one SCTLR_EL1 write "
            "in kernel_mmu_activate, found %d" % len(writes)
        ]

    write_index, write_addr, _, write_match = writes[0]
    target_reg = write_match.group(1)
    producer = None
    for _, text in reversed(body[:write_index]):
        # Stores name their source register first. They preserve that
        # register and may appear here in debug builds when LLVM spills the
        # value for DWARF, so they are not a definition that stops the search.
        if NO_GPR_DEST_RE.match(text):
            continue
        dest = DEST_REG_RE.match(text)
        if dest and dest.group(1) == target_reg:
            producer = text
            break

    clears_a = False
    mask = sctlr_and_mask(body, write_index, target_reg, producer)
    if mask is not None:
        clears_a = mask & (1 << 1) == 0

    if not clears_a:
        failures.append(
            "issue #480 regression: SCTLR_EL1 write at 0x%x is not "
            "immediately fed by an AND/BIC that clears SCTLR_EL1.A (bit 1); "
            "the AArch64 backend may emit pair/vector accesses aligned only "
            "to their scalar elements" % write_addr
        )
    return failures



# GitHub issue #1032: SCTLR_EL1.WXN (bit 19) makes every writable mapping
# execute-never at EL1 and EL0, so code written into a data page can never
# run. The one SCTLR_EL1 write in kernel_mmu_activate must OR it in. LLVM
# folds the source's constant bits into one register built by mov/movk (or
# an orr immediate), so this reconstructs each register's constant from
# those and collects every bit an `orr` contributes before the write.
SCTLR_WXN = 1 << 19
CONST_MOV_RE = re.compile(
    r"^mov[z]?\s+[wx](\d+),\s*#(-?0x[0-9a-f]+|-?\d+)(?:,\s*lsl\s*#(\d+))?$")
CONST_MOVK_RE = re.compile(
    r"^movk\s+[wx](\d+),\s*#(0x[0-9a-f]+|\d+)(?:,\s*lsl\s*#(\d+))?$")
ORR_REG_RE = re.compile(r"^orr\s+[wx]\d+,\s*[wx](\d+),\s*[wx](\d+)$")
ORR_ANY_IMM_RE = re.compile(
    r"^orr\s+[wx]\d+,\s*[wx]\d+,\s*#(0x[0-9a-f]+|\d+)$")


def check_sctlr_sets_wxn(insns):
    body = [text.split("//")[0].strip() for _, text, fn in insns
            if fn == "kernel_mmu_activate"]
    writes = [i for i, text in enumerate(body) if SCTLR_WRITE_RE.match(text)]
    if len(writes) != 1:
        return [
            "issue #1032 regression: expected exactly one SCTLR_EL1 write in "
            "kernel_mmu_activate, found %d, so SCTLR_EL1.WXN is unverified"
            % len(writes)
        ]
    consts = {}
    ored = 0
    for text in body[:writes[0]]:
        m = CONST_MOV_RE.match(text)
        if m:
            consts[m.group(1)] = (int(m.group(2), 0)
                                  << int(m.group(3) or 0)) & (2**64 - 1)
            continue
        m = CONST_MOVK_RE.match(text)
        if m:
            shift = int(m.group(3) or 0)
            old = consts.get(m.group(1), 0) & ~(0xFFFF << shift)
            consts[m.group(1)] = old | (int(m.group(2), 0) << shift)
            continue
        m = ORR_ANY_IMM_RE.match(text)
        if m:
            ored |= int(m.group(1), 0)
            continue
        m = ORR_REG_RE.match(text)
        if m:
            ored |= consts.get(m.group(1), 0) | consts.get(m.group(2), 0)
    if ored & SCTLR_WXN == 0:
        return [
            "issue #1032 regression: no orr before the SCTLR_EL1 write in "
            "kernel_mmu_activate contributes SCTLR_EL1.WXN (bit 19); a "
            "writable kernel or user page could be executed"
        ]
    return []


# GitHub issue #1032: SCTLR_EL1.SPAN (bit 23) must be clear so every
# exception taken to EL1 sets PSTATE.PAN; with it set (its reset value) a
# syscall from EL0 would enter with PAN as EL0 left it, clear, and every
# EL1 access to user memory would succeed outside a user_access window.
SCTLR_SPAN = 1 << 23


def check_sctlr_clears_span(insns):
    body = [(addr, text.split("//")[0].strip()) for addr, text, fn in insns
            if fn == "kernel_mmu_activate"]
    writes = [(i, SCTLR_WRITE_RE.match(text)) for i, (_, text)
              in enumerate(body) if SCTLR_WRITE_RE.match(text)]
    if len(writes) != 1:
        return [
            "issue #1032 regression: expected exactly one SCTLR_EL1 write in "
            "kernel_mmu_activate, found %d, so SCTLR_EL1.SPAN is unverified"
            % len(writes)
        ]
    write_index, match = writes[0]
    target_reg = match.group(1)
    producer = None
    for _, text in reversed(body[:write_index]):
        if NO_GPR_DEST_RE.match(text):
            continue
        dest = DEST_REG_RE.match(text)
        if dest and dest.group(1) == target_reg:
            producer = text
            break
    mask = sctlr_and_mask(body, write_index, target_reg, producer)
    if mask is None or mask & SCTLR_SPAN:
        return [
            "issue #1032 regression: the SCTLR_EL1 write in "
            "kernel_mmu_activate is not fed by an AND that clears "
            "SCTLR_EL1.SPAN (bit 23); an exception from EL0 would enter EL1 "
            "with PAN clear"
        ]
    return []


# GitHub issue #1032: PSTATE.PAN is written only by the three
# user-access leaves in user_entry.S: cleared (MSR PAN, #0) only in
# user_access_open, set (MSR PAN, #1) only in user_access_close and
# user_access_pan_enable. Their Takibi callers are fixed by
# scripts/allowed_callers.tsv; this pins the instructions themselves, so a
# PAN write cannot appear anywhere else in the linked kernel.
PAN_WRITE_RE = re.compile(r"^msr\s+PAN,\s*#(0x[0-9a-f]+|\d+)$", re.IGNORECASE)
PAN_WRITERS = {"0": {"user_access_open"},
               "1": {"user_access_close", "user_access_pan_enable"}}


def check_pan_writes(insns):
    failures = []
    seen = {"user_access_open": 0, "user_access_close": 0,
            "user_access_pan_enable": 0}
    for addr, text, fn in insns:
        m = PAN_WRITE_RE.match(text.split("//")[0].strip())
        if not m:
            continue
        if fn not in PAN_WRITERS.get(str(int(m.group(1), 0)), set()):
            failures.append(
                "issue #1032 regression: PSTATE.PAN write `%s` at 0x%x in %s, "
                "outside the user-access leaves" % (text.strip(), addr, fn))
        else:
            seen[fn] += 1
    for fn, count in seen.items():
        if count != 1:
            failures.append(
                "issue #1032 regression: expected one PSTATE.PAN write in %s, "
                "found %d" % (fn, count))
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
    # GitHub issue #920: the save is irq_save, which masks only when IRQs were
    # not already masked. It counts only if it reaches both masks: the GIC
    # priority mask and the DAIF fallback. GitHub issue #1288: it holds them
    # itself, one preempt_off region rather than disable_irq's second one.
    irq_save = [text for _, text, fn in insns if fn == "irq_save"]
    irq_save_masks = (any("<irq_priority_mask_write>" in x for x in irq_save)
                      and any("DAIFSet" in x for x in irq_save))
    if saver and not any("<disable_irq>" in x or "DAIFSet" in x
                         or ("<irq_save>" in x and irq_save_masks)
                         for x in saver):
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


# GitHub issue #477: every exception entry's stack switch must be PER CORE.
#
# The generated entries compute a stack address and `mov sp` to it. With one
# global irq_stack_top that address was the same on every core, so the
# second core's first interrupt landed on the first core's saved frame --
# measured, not theorised: core 1's timer INTID (30) arrived as core 0's
# ELR. The fix adds this core's offset, from TPIDR_EL1, to the address the
# entry already computed.
#
# Checked on emitted instructions because the failure is invisible on one
# core and unattributable on two. A `mov sp, xN` with no `mrs xM, tpidr_el1`
# feeding it is correct on every single-core test that will ever be run.
#
# Deliberately NOT a check that some tpidr_el1 read exists somewhere in the
# function: the question is whether THIS stack switch uses one. So the walk
# pairs them up in order, which also catches an entry that reads the
# register once and then switches stacks twice.
ENTRY_SUFFIXES = ("_irq_entry", "_sync_entry")
MOV_SP_RE = re.compile(r"^mov\s+sp,\s*x(\d+)$")
# llvm-objdump prints system register names in UPPERCASE (the DAIFSet
# check above relies on the same fact).
MRS_TPIDR_RE = re.compile(r"^mrs\s+x(\d+),\s*tpidr_el1$", re.I)
ADD_RE = re.compile(r"^add\s+x(\d+),\s*x(\d+),\s*x(\d+)$")


def check_exception_stacks_are_per_core(insns):
    failures = []
    bodies = {}
    for _, text, fn in insns:
        if fn and fn.endswith(ENTRY_SUFFIXES):
            bodies.setdefault(fn, []).append(text)
    if not bodies:
        failures.append(
            "no exception entry found in this image: the generated entries "
            "are what this checks, and a build without them has either "
            "renamed them or stopped emitting them"
        )
        return failures

    total_switches = 0
    for fn, body in sorted(bodies.items()):
        # Registers currently known to carry this core's offset, and those
        # known to be a per-core stack address derived from it.
        offset_regs = set()
        percore_regs = set()
        switches = 0
        for text in body:
            m = MRS_TPIDR_RE.match(text)
            if m:
                offset_regs.add(m.group(1))
                continue
            m = ADD_RE.match(text)
            if m:
                dst, a, b = m.groups()
                if a in offset_regs or b in offset_regs:
                    percore_regs.add(dst)
                else:
                    percore_regs.discard(dst)
                continue
            m = MOV_SP_RE.match(text)
            if m:
                switches += 1
                # The dispatch's RETURNED sp (x0) is a frame pointer the
                # handler chose, not a stack this entry located, so it is
                # not part of this claim.
                if m.group(1) == "0":
                    continue
                if m.group(1) not in percore_regs:
                    failures.append(
                        "%s switches to a stack in x%s that no tpidr_el1 "
                        "offset was added to: that address is the same on "
                        "every core, so a second core taking this exception "
                        "lands on the first core's frame" % (fn, m.group(1))
                    )
        total_switches += switches
    # Not per entry: el0_sync_entry legitimately switches to nothing, since
    # a syscall runs on the process's own kernel stack. What would be a
    # silent regression is the generator emitting NO stack switch anywhere,
    # which would make every check above pass by having nothing to check.
    if total_switches == 0:
        failures.append(
            "no exception entry switches stacks at all: every check above "
            "passed by finding nothing, which is not the same as passing"
        )
    return failures


# GitHub issue #532: logical Running publication does not prove that the old
# CPU has left a process's physical kernel stack. Both generated paths that
# return to EL0 must call the ownership hook after selecting the returned
# frame as SP, with IRQs masked. `after_switch` is optional language syntax,
# so compiler tests can prove its lowering while still letting a kernel caller
# accidentally omit the key. Check the linked image, which is the contract the
# CPU actually executes.
STACK_SWITCH_FUNCTIONS = ("el0_irq_entry", "el0_context_resume")
STACK_SWITCH_HOOK = "kernel_process_stack_switch_complete"
# GitHub issue #846: the interrupt return calls a wrapper that runs the
# hook first and then the TCP retransmit pass; the syscall return calls
# the hook itself, and nothing the hook reaches runs the pass (maintainer,
# 2026-10-24: softirq work at irq_exit, never on the way out of a syscall).
IRQ_RETURN_HOOK = "kernel_irq_return_complete"
RETRANSMIT_PASS = "kernel_net_retransmit_pass"
STACK_SWITCH_CALLS = {
    "el0_irq_entry": IRQ_RETURN_HOOK,
    "el0_context_resume": STACK_SWITCH_HOOK,
}


def check_process_stack_handoff_hook(insns):
    failures = []
    bodies = {}
    for _, text, fn in insns:
        if fn in STACK_SWITCH_FUNCTIONS:
            bodies.setdefault(fn, []).append(text)

    select_returned_sp = re.compile(r"^mov\s+sp,\s*x0$", re.I)
    mask_irqs = re.compile(r"^msr\s+DAIFSet,\s*#0x2$", re.I)
    unmask_irqs = re.compile(r"^msr\s+DAIFClr,\s*#0x2$", re.I)
    pass_current_sp = re.compile(r"^mov\s+x0,\s*sp$", re.I)
    for fn in STACK_SWITCH_FUNCTIONS:
        hook = STACK_SWITCH_CALLS[fn]
        call_hook = re.compile(r"^bl\s+.*<%s>$" % hook)
        body = bodies.get(fn)
        if body is None:
            failures.append(
                "issue #532 regression: %s is absent, so its process-stack "
                "handoff boundary cannot be verified" % fn)
            continue
        found = False
        for hook_index, text in enumerate(body):
            if not call_hook.match(text):
                continue
            if hook_index == 0 or not pass_current_sp.match(
                    body[hook_index - 1]):
                continue
            before_hook = body[:hook_index - 1]
            selected = any(select_returned_sp.match(item)
                           for item in before_hook)
            mask_indexes = [
                index for index, item in enumerate(before_hook)
                if mask_irqs.match(item)
            ]
            masked = bool(mask_indexes) and not any(
                unmask_irqs.match(item)
                for item in before_hook[mask_indexes[-1] + 1:]
            )
            if selected and masked:
                found = True
                break
        if not found:
            failures.append(
                "issue #532 regression: %s does not select the returned "
                "frame and call %s with its current SP while IRQs remain "
                "masked; another CPU "
                "could acquire the process stack before this CPU leaves it"
                % (fn, hook))
    failures += check_retransmit_pass_placement(insns)
    return failures


def call_graph(insns):
    """Direct `bl` edges between the image's functions."""
    edges = {}
    target = re.compile(r"^bl\s+0x[0-9a-f]+\s+<([\w.$]+)>$", re.I)
    for _, text, fn in insns:
        match = target.match(text)
        if match:
            edges.setdefault(fn, set()).add(match.group(1))
    return edges


def check_retransmit_pass_placement(insns):
    """#846: only the interrupt return reaches the retransmit pass."""
    failures = []
    wrapper = [text for _, text, fn in insns if fn == IRQ_RETURN_HOOK]
    calls = [text for text in wrapper if re.match(r"^bl\s", text)]
    hook_call = re.compile(r"^bl\s+.*<%s>$" % STACK_SWITCH_HOOK)
    pass_call = re.compile(r"^bl\s+.*<%s>$" % RETRANSMIT_PASS)
    if (not calls or not hook_call.match(calls[0]) or
            not any(pass_call.match(text) for text in calls[1:])):
        failures.append(
            "issue #846 regression: %s must call %s first, with the frame "
            "address it was given, and then %s" %
            (IRQ_RETURN_HOOK, STACK_SWITCH_HOOK, RETRANSMIT_PASS))
    elif any(re.match(r"^(?:mov|ldr|add|sub)\s+x0,", text)
             for text in wrapper[:wrapper.index(calls[0])]):
        failures.append(
            "issue #846 regression: %s changes x0 before it calls %s" %
            (IRQ_RETURN_HOOK, STACK_SWITCH_HOOK))
    else:
        # The pass runs unmasked, so DAIF.I must be set again after the last
        # call to it and before every return: the generated restore that
        # follows the hook relies on it (maintainer, 2026-10-24).
        mask = re.compile(r"^msr\s+DAIFSet,\s*#0x[2-9a-f]$", re.I)
        unmask = re.compile(r"^msr\s+DAIFClr,\s*#0x[2-9a-f]$", re.I)
        last_pass = max(index for index, text in enumerate(wrapper)
                        if pass_call.match(text))
        for index, text in enumerate(wrapper):
            if not re.match(r"^ret\b", text) or index < last_pass:
                continue
            between = wrapper[last_pass + 1:index]
            masked = [i for i, item in enumerate(between) if mask.match(item)]
            if not masked or any(unmask.match(item)
                                 for item in between[masked[-1] + 1:]):
                failures.append(
                    "issue #846 regression: %s returns after %s without "
                    "setting DAIF.I again" % (IRQ_RETURN_HOOK, RETRANSMIT_PASS))
                break
    edges = call_graph(insns)
    seen = set()
    stack = [STACK_SWITCH_HOOK]
    while stack:
        fn = stack.pop()
        if fn in seen:
            continue
        seen.add(fn)
        if fn == RETRANSMIT_PASS:
            failures.append(
                "issue #846 regression: %s reaches %s, so every syscall "
                "return would run the TCP retransmit pass" %
                (STACK_SWITCH_HOOK, RETRANSMIT_PASS))
            break
        stack.extend(edges.get(fn, ()))
    return failures


# GitHub issue #920: the IRQ mask is the GIC priority mask, which is per CPU,
# not per frame. Every eret to EL0 must reset it to unmasked, or EL0 runs with
# its ordinary interrupts held at the GIC. An eret is an EL0 return unless its
# function is one of the EL1 returns below. Each EL0 eret must be preceded,
# since the function's previous eret, by a call to irq_mask_reset_el0 or to
# the stack-handoff hook, and the hook itself must call irq_mask_reset_el0.
EL1_ERET_FUNCTIONS = {
    "el1_current_irq_entry": "returns to the interrupted EL1 context",
    "el1_current_sync_entry": "returns to the interrupted EL1 context",
    "el2_drop_to_el1": "cold boot, EL2 to EL1",
}
PMR_RESET = "irq_mask_reset_el0"


def check_el0_return_resets_pmr(insns):
    failures = []
    bodies = {}
    for _, text, fn in insns:
        bodies.setdefault(fn, []).append(text)
    calls = lambda text, name: re.match(r"^bl\s+.*<%s>$" % name, text)
    hook = bodies.get(STACK_SWITCH_HOOK)
    if hook is None or not any(calls(t, PMR_RESET) for t in hook):
        failures.append("issue #920 regression: %s does not call %s, so an "
                        "EL0 return through it may leave the GIC priority "
                        "mask raised" % (STACK_SWITCH_HOOK, PMR_RESET))
    # GitHub issue #846: the interrupt return's wrapper runs the retransmit
    # pass after the hook, so it must reset the mask again after the pass.
    wrapper = bodies.get(IRQ_RETURN_HOOK, [])
    pass_calls = [i for i, t in enumerate(wrapper) if calls(t, RETRANSMIT_PASS)]
    if not pass_calls or not any(calls(t, PMR_RESET)
                                 for t in wrapper[pass_calls[-1] + 1:]):
        failures.append("issue #920 regression: %s does not call %s after "
                        "%s, so an EL0 return through it may leave the GIC "
                        "priority mask raised"
                        % (IRQ_RETURN_HOOK, PMR_RESET, RETRANSMIT_PASS))
    checked = 0
    for fn, body in bodies.items():
        if fn in EL1_ERET_FUNCTIONS:
            continue
        reset = False
        for text in body:
            if (calls(text, PMR_RESET) or calls(text, STACK_SWITCH_HOOK) or
                    calls(text, IRQ_RETURN_HOOK)):
                reset = True
            if re.match(r"^eret$", text):
                checked += 1
                if not reset:
                    failures.append(
                        "issue #920 regression: %s returns to EL0 with no "
                        "call to %s or %s before its eret; EL0 would run "
                        "with the GIC priority mask possibly raised"
                        % (fn, PMR_RESET, STACK_SWITCH_HOOK))
                reset = False
    if checked == 0:
        failures.append("issue #920: no EL0 eret was found, so the priority "
                        "mask reset was checked against nothing")
    return failures


STOP_ENTRIES = ("kernel_invariant_stop", "kernel_invariant_stop_with_frame")


def check_invariant_stop_capture(insns):
    """Pin the trusted LR capture and the supported direct-call ABI."""
    failures = []
    for entry in STOP_ENTRIES:
        body = [re.sub(r"\s+", " ", text.split("//", 1)[0]).strip().lower()
                for _, text, function in insns if function == entry]
        context = "mov x1, xzr" if entry == STOP_ENTRIES[0] else "mov x1, x0"
        if (len(body) != 5 or body[:4] != ["msr daifset, #0xf", "mov x2, x30",
                                         context, "mov x0, #0x1"] or
                not re.fullmatch(r"b 0x[0-9a-f]+ <kernel_invariant_evidence>", body[-1])):
            failures.append(f"explicit stop {entry}: incoming LR/origin capture unverified")
    # Only a branch reaches a stop. objdump also labels an adrp page or an
    # adr/ldr literal with the nearest symbol, so a jump table that happens
    # to sit in the stop's page reads as `<kernel_invariant_stop+0x4>`
    # without referring to it.
    branch = re.compile(r"(?:bl?|b\.\w+|cbn?z|tbn?z)\s")
    for address, text, _ in insns:
        if not branch.match(text):
            continue
        if any(re.search(r"<" + entry + r"(?:[+>])", text) for entry in STOP_ENTRIES):
            if not re.fullmatch(r"bl\s+0x[0-9a-f]+ <kernel_invariant_stop(?:_with_frame)?>", text):
                failures.append(f"explicit stop at 0x{address:x}: unsupported call instruction")
    return failures


# GitHub issue #746: the page allocator's MMU-off entry points run on
# Device memory, where an unaligned access faults. LLVM merged two
# adjacent 8-byte zero stores into one 128-bit `str q0, [x19, x8]` at an
# 8-mod-16 offset of the 16-aligned pool; the RPi5 then never printed a
# byte (QEMU does not enforce the alignment). A q-register store in these
# functions must use an immediate offset that is a multiple of 16.
MMU_OFF_ALLOCATOR_FUNCTIONS = (
    "page_allocator_init", "page_allocator_init_with", "page_alloc_boot",
    "page_alloc_locked", "page_free_boot", "page_free_locked",
    "page_freelist_push",
)


# GitHub issue #762: every function an `!{mmu_off}` root reaches, read from
# the compiler's call graph (main.o.facts/callgraph.tsv, docs/CALL_GRAPH.md):
# the compiler compiles these +strict-align, and this check is the
# backstop over the same set rather than over a hand list.
def mmu_off_reachable(callgraph_path):
    rows = {}
    with open(callgraph_path) as handle:
        lines = [line.rstrip("\n") for line in handle if not line.startswith("#")]
    header = lines[0].split("\t")
    name_at = header.index("name")
    declared_at = header.index("declared")
    callees_at = header.index("callees")
    roots = []
    for line in lines[1:]:
        fields = line.split("\t")
        callees = [] if fields[callees_at] == "-" else [
            c.split("@", 1)[0] for c in fields[callees_at].split(",")]
        rows[fields[name_at]] = callees
        if "mmu_off" in fields[declared_at].split(","):
            roots.append(fields[name_at])
    seen = set()
    stack = list(roots)
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        stack.extend(rows.get(name, []))
    return roots, seen
Q_STORE_RE = re.compile(r"^(?:str|stur|stp|stnp)\s+q\d+,(?:\s*q\d+,)?\s*\[(.*?)\]")


def check_mmu_off_vector_stores(insns, mmu_off_functions=None):
    failures = []
    seen = set()
    checked = set(MMU_OFF_ALLOCATOR_FUNCTIONS)
    if mmu_off_functions is not None:
        missing = checked - mmu_off_functions
        if missing:
            failures.append(
                "issue #762: the call graph's MMU-off set lacks %s, which the "
                "#746 list names" % ", ".join(sorted(missing)))
        checked |= mmu_off_functions
    for address, text, function in insns:
        if function not in checked:
            continue
        seen.add(function)
        m = Q_STORE_RE.match(text)
        if not m:
            continue
        operands = [part.strip() for part in m.group(1).split(",")]
        offset = 0
        if len(operands) == 2 and operands[1].startswith("#"):
            offset = int(operands[1][1:], 0)
        elif len(operands) != 1:
            failures.append(
                "issue #746: %s stores a q register through a register "
                "offset at 0x%x (%s); with the MMU off that address may be "
                "8-mod-16 and fault on Device memory" % (function, address, text))
            continue
        if offset % 16 != 0:
            failures.append(
                "issue #746: %s stores a q register at an offset %d that is "
                "not a multiple of 16 at 0x%x (%s)" % (function, offset, address, text))
    for function in ("page_allocator_init_with", "page_alloc_boot"):
        if function not in seen:
            failures.append("issue #746: %s is absent; the MMU-off vector store "
                            "check examined nothing" % function)
    return failures


# GitHub issue #1133 ("assembly is a leaf", DECISIONS 2026-10-25): a value
# that crosses hand-written assembly loses its type, so assembly may enter
# Takibi only at a declared entry point -- the Makefile's KERNEL_ASM_ENTRIES,
# the same list the compiler's unused-function check is given. Read from the
# assembly objects' own relocations: every symbol an assembly object
# references and no assembly object defines, that the Takibi object defines
# as a function, must be declared; and every declared entry must still be
# referenced, so retiring a call from assembly retires its entry too (the
# shape #1080 left behind: user_entry.S's action 8 called back into
# kernel_syscall_child_exec_return, and the entry would otherwise have
# outlived the call). The symbols below are compiler-generated assembly,
# not Takibi functions, and are referenced by name for that reason.
ASM_GENERATED_SYMBOLS = {
    # The exception vector table exception_frame.tkb declares; entry.S
    # installs it in VBAR_EL1.
    "el1_vectors",
}


def nm_symbols(obj):
    """(defined function names, defined names, undefined names) of `obj`."""
    out = subprocess.run(["llvm-nm-19", obj], check=True,
                         capture_output=True, text=True).stdout
    functions, defined, undefined = set(), set(), set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "U":
            undefined.add(parts[1])
        elif len(parts) == 3:
            defined.add(parts[2])
            if parts[1] in ("T", "t"):
                functions.add(parts[2])
    return functions, defined, undefined


def asm_takibi_entry_problems(entries, takibi_symbols, asm_symbols):
    """Problems with assembly's calls into Takibi.

    `takibi_symbols` is the Takibi object's function names; `asm_symbols`
    maps each assembly object to its (defined, undefined) names."""
    asm_defined = set()
    for defined, _ in asm_symbols.values():
        asm_defined |= defined
    problems = []
    referenced = set()
    for obj, (_, undefined) in sorted(asm_symbols.items()):
        for name in sorted(undefined - asm_defined):
            if name not in takibi_symbols or name in ASM_GENERATED_SYMBOLS:
                continue
            referenced.add(name)
            if name not in entries:
                problems.append(
                    f"{obj} enters Takibi at {name}, which is not a declared "
                    "assembly entry (KERNEL_ASM_ENTRIES): assembly is a leaf "
                    "(#1133); declare it only after review")
    for name in sorted(entries - referenced):
        problems.append(
            f"{name} is a declared assembly entry (KERNEL_ASM_ENTRIES) that "
            "no assembly object references any more; remove it")
    return problems


def check_asm_takibi_entries(entries, takibi_object, asm_objects):
    takibi_functions, _, _ = nm_symbols(takibi_object)
    asm_symbols = {}
    for obj in asm_objects:
        _, defined, undefined = nm_symbols(obj)
        asm_symbols[obj] = (defined, undefined)
    return asm_takibi_entry_problems(set(entries), takibi_functions,
                                     asm_symbols)


def asm_takibi_entry_controls():
    """The entry rule must refuse both shapes it exists for."""
    asm = {"user_entry.o": ({"el0_sync_body"},
                            {"kernel_syscall_dispatch", "boot_stack_top"})}
    takibi = {"kernel_syscall_dispatch", "kernel_syscall_child_exec_return"}
    failures = []
    if asm_takibi_entry_problems({"kernel_syscall_dispatch"}, takibi, asm):
        failures.append("asm-entry control: a declared entry was refused")
    undeclared = {"user_entry.o": ({"el0_sync_body"},
                                   {"kernel_syscall_dispatch",
                                    "kernel_syscall_child_exec_return"})}
    if not asm_takibi_entry_problems({"kernel_syscall_dispatch"}, takibi,
                                     undeclared):
        failures.append("asm-entry control: an undeclared entry was accepted")
    if not asm_takibi_entry_problems(
            {"kernel_syscall_dispatch", "kernel_syscall_child_exec_return"},
            takibi, asm):
        failures.append("asm-entry control: a stale entry was accepted")
    return failures


def check_mmu_off_from_graph(insns, takibi_object):
    """The #762 set: every MMU-off-reachable function in the Takibi
    object's call graph, which must include the #746 list."""
    graph = takibi_object + ".facts/callgraph.tsv"
    if not os.path.exists(graph):
        return [f"issue #762: {graph} is missing; the MMU-off set comes from it"]
    roots, reachable = mmu_off_reachable(graph)
    if not roots:
        return [f"issue #762: {graph} names no !{{mmu_off}} root"]
    return check_mmu_off_vector_stores(insns, reachable)


def main():
    args = sys.argv[1:]
    entries = None
    takibi_object = None
    asm_objects = []
    if "--asm-entries" in args:
        at = args.index("--asm-entries")
        tail = args[at:]
        args = args[:at]
        try:
            entries = tail[1].split()
            if tail[2] != "--takibi-object":
                raise IndexError
            takibi_object = tail[3]
            asm_objects = tail[4:]
        except IndexError:
            asm_objects = []
        if not asm_objects:
            print("usage: ... --asm-entries \"NAMES\" --takibi-object "
                  "MAIN.o ASM.o...", file=sys.stderr)
            return 1
    if len(args) != 2:
        print(
            "usage: buildcheck_kernel_asm_invariants.py <kernel.elf> "
            "<expected_device_block_uxn_pxn_count> "
            "[--asm-entries \"NAMES\" --takibi-object MAIN.o ASM.o...]",
            file=sys.stderr,
        )
        return 1
    elf_path = args[0]
    expected_uxn_and_pxn_count = int(args[1])
    insns = parse_instructions(objdump_lines(elf_path))
    entry_failures = []
    if entries is not None:
        entry_failures = (asm_takibi_entry_controls() +
                          check_asm_takibi_entries(entries, takibi_object,
                                                   asm_objects))
    failures = (
        entry_failures
        + check_invariant_stop_capture(insns)
        + check_uxn(insns, expected_uxn_and_pxn_count)
        + check_eret_daif_mask(insns)
        + check_spinlock_is_atomic(insns, elf_path)
        + check_sctlr_allows_normal_memory_unaligned_access(insns)
        + check_sctlr_sets_wxn(insns)
        + check_sctlr_clears_span(insns)
        + check_pan_writes(insns)
        + check_mutex_masks_before_taking(insns)
        + check_tlb_invalidate_all_is_broadcast(insns)
        + check_exception_stacks_are_per_core(insns)
        + check_process_stack_handoff_hook(insns)
        + check_el0_return_resets_pmr(insns)
        + (check_mmu_off_from_graph(insns, takibi_object)
           if takibi_object is not None
           else check_mmu_off_vector_stores(insns))
    )
    if failures:
        for f in failures:
            print("FAIL kernel/asm-invariants: %s" % f, file=sys.stderr)
        return 1
    report_pass("kernel/asm-invariants", "UXN identity-block bits, eret DAIF.I "
          "masking, SCTLR_EL1.A clear, WXN set and SPAN clear, PSTATE.PAN written only by the user-access leaves, the spinlock's "
          "target-selected compare-exchange, mutex_acquire masking "
          "before it takes, the whole-TLB invalidate broadcasting "
          "while MMU activation stays local, and every exception entry "
          "switching to a stack of its own core, with every EL0 process "
          "return crossing the physical stack-handoff hook and resetting the GIC priority mask (only the interrupt return reaching the TCP retransmit pass), and no misaligned "
          "q-register store in the MMU-off page allocator, all verified "
          "statically" + (", and assembly entering Takibi only at its %d "
          "declared entries (#1133)" % len(entries) if entries is not None
          else ""),
                insns=len(insns))
    return 0


if __name__ == "__main__":
    sys.exit(main())
