#!/usr/bin/env python3
"""Controls for the SCTLR alignment-policy disassembly check."""

import check_kernel_asm_invariants as checker


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


def main():
    accepted = [
        "and x8, x8, #0xfffffffffffffffd",
        "bic x8, x8, #0x2",
    ]
    for producer in accepted:
        failures = checker.check_sctlr_allows_normal_memory_unaligned_access(
            body(producer)
        )
        if failures:
            print("FAIL kernel-asm-alignment control: accepted form failed")
            return 1

    failures = checker.check_sctlr_allows_normal_memory_unaligned_access(
        body("and x8, x8, #0xfffffffffffffffd", spill=True)
    )
    if failures:
        print("FAIL kernel-asm-alignment control: debug spill hid A-bit clear")
        return 1

    failures = checker.check_sctlr_allows_normal_memory_unaligned_access(
        body("orr x8, x8, #0x2")
    )
    if len(failures) != 1 or "SCTLR_EL1.A" not in failures[0]:
        print("FAIL kernel-asm-alignment control: A-bit set was not rejected")
        return 1

    failures = checker.check_sctlr_allows_normal_memory_unaligned_access([])
    if len(failures) != 1 or "unverified" not in failures[0]:
        print("FAIL kernel-asm-alignment control: missing function passed")
        return 1

    print("PASS kernel-asm-alignment controls: A-bit clear accepted, set rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
