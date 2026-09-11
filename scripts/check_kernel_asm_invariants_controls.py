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

    handoff_ok = [
        (0x2000, "mov sp, x0", "el0_irq_entry"),
        (0x2004, "msr DAIFSet, #0x2", "el0_irq_entry"),
        (0x2008, "mov x0, sp", "el0_irq_entry"),
        (0x200C, "bl 0x3000 <kernel_process_stack_switch_complete>",
         "el0_irq_entry"),
        (0x2100, "mov sp, x0", "el0_context_resume"),
        (0x2104, "msr DAIFSet, #0x2", "el0_context_resume"),
        (0x2108, "mov x0, sp", "el0_context_resume"),
        (0x210C, "bl 0x3000 <kernel_process_stack_switch_complete>",
         "el0_context_resume"),
    ]
    CASES.note()
    if checker.check_process_stack_handoff_hook(handoff_ok):
        print("FAIL kernel-asm-alignment control: valid stack handoff failed")
        return 1

    CASES.note()
    missing = checker.check_process_stack_handoff_hook(
        [item for item in handoff_ok if item[2] != "el0_context_resume"])
    if len(missing) != 1 or "el0_context_resume is absent" not in missing[0]:
        print("FAIL kernel-asm-alignment control: missing return path passed")
        return 1

    CASES.note()
    wrong_order = list(handoff_ok)
    wrong_order[1], wrong_order[2] = wrong_order[2], wrong_order[1]
    failures = checker.check_process_stack_handoff_hook(wrong_order)
    if len(failures) != 1 or "does not select" not in failures[0]:
        print("FAIL kernel-asm-alignment control: reordered handoff passed")
        return 1

    report_pass(
        "kernel-asm-alignment controls",
        "A-bit clear accepted and set rejected; both physical stack-handoff "
        "paths required in order",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
