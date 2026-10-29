#!/usr/bin/env python3
"""Offline controls for kernel linked-assembly invariant checks."""

import buildcheck_kernel_asm_invariants as checker

from pass_line import CaseCount, report_pass


def body(producer, spill=False):
    insns = [
        (0x1000, "mrs x8, SCTLR_EL1", "kernel_mmu_activate"),
        (0x1004, "orr w8, w8, w9", "kernel_mmu_activate"),
        (0x1008, producer, "kernel_mmu_activate"),
    ]
    if spill:
        insns.append((0x100C, "str x8, [sp, #0x8]", "kernel_mmu_activate"))
    insns.append((0x1010, "msr SCTLR_EL1, x8", "kernel_mmu_activate"))
    return insns


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def verdict(insns):
    """One scenario: hand the checker a body and take its findings."""
    CASES.note()
    return checker.check_sctlr_allows_normal_memory_unaligned_access(insns)


def main():
    accepted = [
        "and x8, x8, #0xfffffffffffffffd",
        "bic x8, x8, #0x2",
    ]
    for producer in accepted:
        failures = verdict(body(producer))
        if failures:
            print("FAIL kernel-asm-alignment control: accepted form failed")
            return 1

    failures = verdict(body("and x8, x8, #0xfffffffffffffffd", spill=True))
    if failures:
        print("FAIL kernel-asm-alignment control: debug spill hid A-bit clear")
        return 1

    failures = verdict(body("orr x8, x8, #0x2"))
    if len(failures) != 1 or "SCTLR_EL1.A" not in failures[0]:
        print("FAIL kernel-asm-alignment control: A-bit set was not rejected")
        return 1

    failures = verdict([])
    if len(failures) != 1 or "unverified" not in failures[0]:
        print("FAIL kernel-asm-alignment control: missing function passed")
        return 1

    # GitHub issue #1032: SCTLR_EL1.WXN reconstructed through mov/movk.
    def wxn_body(movk):
        return [
            (0x5000, "mov w9, #0x1005             // =4101", "kernel_mmu_activate"),
            (0x5004, movk, "kernel_mmu_activate"),
            (0x5008, "mrs x8, SCTLR_EL1", "kernel_mmu_activate"),
            (0x500C, "orr x8, x8, x9", "kernel_mmu_activate"),
            (0x5010, "and x8, x8, #0xfffffffffffffffd", "kernel_mmu_activate"),
            (0x5014, "msr SCTLR_EL1, x8", "kernel_mmu_activate"),
        ]
    CASES.note()
    if checker.check_sctlr_sets_wxn(wxn_body("movk w9, #0x8, lsl #16")):
        print("FAIL kernel-asm-wxn control: a WXN-setting write was refused")
        return 1
    CASES.note()
    failures = checker.check_sctlr_sets_wxn(wxn_body("movk w9, #0x0, lsl #16"))
    if len(failures) != 1 or "WXN" not in failures[0]:
        print("FAIL kernel-asm-wxn control: a write without WXN passed")
        return 1
    CASES.note()
    failures = checker.check_sctlr_sets_wxn([])
    if len(failures) != 1 or "unverified" not in failures[0]:
        print("FAIL kernel-asm-wxn control: missing function passed")
        return 1

    # GitHub issue #1032: SPAN (bit 23) and A (bit 1) cleared through an AND
    # with a mov/movk-built register, since no logical immediate encodes both.
    def span_body(movk):
        return [
            (0x6000, "mrs x8, SCTLR_EL1", "kernel_mmu_activate"),
            (0x6004, "mov x9, #-0x3               // =-3", "kernel_mmu_activate"),
            (0x6008, movk, "kernel_mmu_activate"),
            (0x600C, "and x8, x8, x9", "kernel_mmu_activate"),
            (0x6010, "msr SCTLR_EL1, x8", "kernel_mmu_activate"),
        ]
    CASES.note()
    good = span_body("movk x9, #0xff7f, lsl #16")
    if (checker.check_sctlr_clears_span(good) or
            checker.check_sctlr_allows_normal_memory_unaligned_access(good)):
        print("FAIL kernel-asm-span control: a SPAN- and A-clearing write was refused")
        return 1
    CASES.note()
    failures = checker.check_sctlr_clears_span(span_body("movk x9, #0xffff, lsl #16"))
    if len(failures) != 1 or "SPAN" not in failures[0]:
        print("FAIL kernel-asm-span control: a write leaving SPAN set passed")
        return 1
    CASES.note()
    failures = checker.check_sctlr_clears_span([])
    if len(failures) != 1 or "unverified" not in failures[0]:
        print("FAIL kernel-asm-span control: missing function passed")
        return 1

    # GitHub issue #1032: PSTATE.PAN written only by the user-access leaves.
    leaves = [
        (0x7000, "msr PAN, #0x1", "user_access_pan_enable"),
        (0x7004, "msr PAN, #0x0", "user_access_open"),
        (0x7008, "msr PAN, #0x1", "user_access_close"),
    ]
    CASES.note()
    if checker.check_pan_writes(leaves):
        print("FAIL kernel-asm-pan control: the three leaves were refused")
        return 1
    CASES.note()
    failures = checker.check_pan_writes(
        leaves + [(0x700C, "msr PAN, #0x0", "copy_from_user")])
    if len(failures) != 1 or "outside the user-access leaves" not in failures[0]:
        print("FAIL kernel-asm-pan control: a PAN clear outside the window passed")
        return 1
    CASES.note()
    failures = checker.check_pan_writes(leaves[:1] + leaves[2:])
    if len(failures) != 1 or "user_access_open" not in failures[0]:
        print("FAIL kernel-asm-pan control: a missing window opener passed")
        return 1

    # GitHub issue #920: every EL0 eret resets the GIC priority mask.
    pmr_ok = [
        (0x3000, "bl 0x4000 <irq_mask_reset_el0>", "kernel_process_stack_switch_complete"),
        (0x3004, "ret", "kernel_process_stack_switch_complete"),
        (0x3400, "bl 0x3000 <kernel_process_stack_switch_complete>", "kernel_irq_return_complete"),
        (0x3404, "bl 0x3c00 <kernel_net_retransmit_pass>", "kernel_irq_return_complete"),
        (0x3408, "bl 0x4000 <irq_mask_reset_el0>", "kernel_irq_return_complete"),
        (0x2000, "bl 0x3400 <kernel_irq_return_complete>", "el0_irq_entry"),
        (0x2004, "eret", "el0_irq_entry"),
        (0x2100, "bl 0x4000 <irq_mask_reset_el0>", "el0_sync_body"),
        (0x2104, "eret", "el0_sync_body"),
        (0x2200, "eret", "el1_current_irq_entry"),
    ]
    CASES.note()
    if checker.check_el0_return_resets_pmr(pmr_ok):
        print("FAIL kernel-asm-pmr control: a correct EL0 return was refused")
        return 1
    CASES.note()
    missing = [i for i in pmr_ok if i[1] != "bl 0x4000 <irq_mask_reset_el0>" or i[2] != "el0_sync_body"]
    failures = checker.check_el0_return_resets_pmr(missing)
    if len(failures) != 1 or "el0_sync_body returns to EL0" not in failures[0]:
        print("FAIL kernel-asm-pmr control: an EL0 eret without the reset passed")
        return 1
    CASES.note()
    hook_without = [i for i in pmr_ok if i[2] != "kernel_process_stack_switch_complete" or i[1] == "ret"]
    failures = checker.check_el0_return_resets_pmr(hook_without)
    if len(failures) != 1 or "does not call irq_mask_reset_el0" not in failures[0]:
        print("FAIL kernel-asm-pmr control: a hook without the reset passed")
        return 1
    # GitHub issue #846: the wrapper resets the mask again after the pass.
    CASES.note()
    failures = checker.check_el0_return_resets_pmr(
        [i for i in pmr_ok if i[0] != 0x3408])
    if len(failures) != 1 or "kernel_irq_return_complete does not call" not in failures[0]:
        print("FAIL kernel-asm-pmr control: a retransmit wrapper without the "
              "reset after the pass passed")
        return 1
    CASES.note()
    failures = checker.check_el0_return_resets_pmr(pmr_ok + [(0x2300, "eret", "new_el0_return")])
    if len(failures) != 1 or "new_el0_return" not in failures[0]:
        print("FAIL kernel-asm-pmr control: an unlisted eret function passed")
        return 1

    handoff_ok = [
        (0x2000, "mov sp, x0", "el0_irq_entry"),
        (0x2004, "msr DAIFSet, #0x2", "el0_irq_entry"),
        (0x2008, "mov x0, sp", "el0_irq_entry"),
        (0x200C, "bl 0x3400 <kernel_irq_return_complete>",
         "el0_irq_entry"),
        (0x2100, "mov sp, x0", "el0_context_resume"),
        (0x2104, "msr DAIFSet, #0x2", "el0_context_resume"),
        (0x2108, "mov x0, sp", "el0_context_resume"),
        (0x210C, "bl 0x3000 <kernel_process_stack_switch_complete>",
         "el0_context_resume"),
        (0x3000, "bl 0x3800 <kernel_signal_return_deliver>",
         "kernel_process_stack_switch_complete"),
        (0x3400, "stp x29, x30, [sp, #-16]!", "kernel_irq_return_complete"),
        (0x3404, "bl 0x3000 <kernel_process_stack_switch_complete>",
         "kernel_irq_return_complete"),
        (0x3408, "msr DAIFClr, #0x2", "kernel_irq_return_complete"),
        (0x340C, "bl 0x3c00 <kernel_net_retransmit_pass>",
         "kernel_irq_return_complete"),
        (0x3410, "msr DAIFSet, #0x2", "kernel_irq_return_complete"),
        (0x3414, "ldp x29, x30, [sp], #16", "kernel_irq_return_complete"),
        (0x3418, "ret", "kernel_irq_return_complete"),
    ]
    CASES.note()
    if checker.check_process_stack_handoff_hook(handoff_ok):
        print("FAIL kernel-asm-alignment control: valid stack handoff failed")
        return 1

    # GitHub issue #846: only the interrupt return reaches the pass.
    CASES.note()
    syscall_pass = handoff_ok + [
        (0x3804, "bl 0x3c00 <kernel_net_retransmit_pass>",
         "kernel_signal_return_deliver")]
    failures = checker.check_process_stack_handoff_hook(syscall_pass)
    if len(failures) != 1 or "every syscall" not in failures[0]:
        print("FAIL kernel-asm-alignment control: a syscall return reaching "
              "the retransmit pass passed")
        return 1

    CASES.note()
    direct_hook = [
        (address, "bl 0x3000 <kernel_process_stack_switch_complete>", fn)
        if address == 0x200C else (address, text, fn)
        for address, text, fn in handoff_ok]
    failures = checker.check_process_stack_handoff_hook(direct_hook)
    if len(failures) != 1 or "el0_irq_entry does not" not in failures[0]:
        print("FAIL kernel-asm-alignment control: an interrupt return "
              "without the retransmit wrapper passed")
        return 1

    CASES.note()
    no_pass = [item for item in handoff_ok if item[0] != 0x340C]
    failures = checker.check_process_stack_handoff_hook(no_pass)
    if len(failures) != 1 or "kernel_irq_return_complete must" not in failures[0]:
        print("FAIL kernel-asm-alignment control: a wrapper without the "
              "pass passed")
        return 1

    CASES.note()
    no_remask = [item for item in handoff_ok if item[0] != 0x3410]
    failures = checker.check_process_stack_handoff_hook(no_remask)
    if len(failures) != 1 or "without setting DAIF.I again" not in failures[0]:
        print("FAIL kernel-asm-alignment control: a wrapper returning "
              "unmasked after the pass passed")
        return 1

    CASES.note()
    missing = checker.check_process_stack_handoff_hook(
        [item for item in handoff_ok if item[2] != "el0_context_resume"])
    if len(missing) != 1 or "el0_context_resume is absent" not in missing[0]:
        print("FAIL kernel-asm-alignment control: missing return path passed")
        return 1

    CASES.note()
    mask_before_select = list(handoff_ok)
    mask_before_select[4], mask_before_select[5] = (
        mask_before_select[5], mask_before_select[4])
    if checker.check_process_stack_handoff_hook(mask_before_select):
        print("FAIL kernel-asm-alignment control: safe mask-first handoff failed")
        return 1

    CASES.note()
    hook_before_select = list(handoff_ok)
    hook_before_select[4], hook_before_select[6] = (
        hook_before_select[6], hook_before_select[4])
    failures = checker.check_process_stack_handoff_hook(hook_before_select)
    if len(failures) != 1 or "does not select" not in failures[0]:
        print("FAIL kernel-asm-alignment control: hook before selection passed")
        return 1

    CASES.note()
    missing_mask = [item for item in handoff_ok
                    if item[:2] != (0x2104, "msr DAIFSet, #0x2")]
    failures = checker.check_process_stack_handoff_hook(missing_mask)
    if len(failures) != 1 or "IRQs remain masked" not in failures[0]:
        print("FAIL kernel-asm-alignment control: unmasked handoff passed")
        return 1

    CASES.note()
    unmasked_before_hook = list(handoff_ok)
    unmasked_before_hook.insert(
        6, (0x2106, "msr DAIFClr, #0x2", "el0_context_resume"))
    failures = checker.check_process_stack_handoff_hook(unmasked_before_hook)
    if len(failures) != 1 or "IRQs remain masked" not in failures[0]:
        print("FAIL kernel-asm-alignment control: intervening unmask passed")
        return 1

    capture = []
    for entry, context in zip(checker.STOP_ENTRIES, ("xzr", "x0")):
        for index, instruction in enumerate(("msr DAIFSet, #0xf", "mov x2, x30",
                f"mov x1, {context}", "mov x0, #0x1",
                "b 0x5000 <kernel_invariant_evidence>")):
            capture.append((0x4000 + len(capture) * 4, instruction, entry))
    capture.append((0x6000, "bl 0x4000 <kernel_invariant_stop>", "caller"))
    CASES.note()
    assert not checker.check_invariant_stop_capture(capture)
    for offset, replacement in ((1, "mov x2, xzr"),
                                (0, "bl 0x5000 <kernel_invariant_evidence>"),
                                (10, "b 0x4000 <kernel_invariant_stop>")):
        mutated = list(capture)
        address, _, function = mutated[offset]
        mutated[offset] = (address, replacement, function)
        CASES.note()
        assert checker.check_invariant_stop_capture(mutated), replacement

    report_pass(
        "kernel-asm-alignment controls",
        "A-bit clear accepted and set rejected; both physical stack-handoff "
        "paths select the returned frame and call with IRQs masked, and a syscall return reaching the TCP retransmit pass is refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
