/* SPDX-License-Identifier: MIT
 * QEMU/AArch64 `virt` machine boot shim (GitHub issue #237). NOT a copy of
 * kernel/arch/arm64/boot/entry.S with the serial numbers filed off --
 * that file's el2_drop_to_el1 exists because RPi5's TF-A hands off control
 * at EL2, and this kernel needs to drop to EL1 itself. QEMU `virt` with a
 * plain `-cpu cortex-a53` (no explicit EL2/EL3 firmware options) starts a
 * `-kernel`-loaded guest directly at EL1 -- confirmed empirically: the
 * first real boot attempt under this port hit a repeating "Undefined
 * Instruction" trap at absolute PC 0x200 (VBAR_EL1's architectural RESET
 * value plus the Current-EL-SPx synchronous-exception vector offset),
 * meaning el2_drop_to_el1's first EL2-only register read (CNTHCTL_EL2)
 * was executing at EL1, where that register does not exist.
 * examples/common_qemu/startup.S (a separate, hardware-proven QEMU
 * bring-up predating this kernel) independently confirms the same fact --
 * it sets VBAR_EL1 directly with no EL2 setup of any kind. This file's
 * structure otherwise mirrors entry.S as closely as the two boot models
 * allow (BSS zeroing, stack setup, PSCI secondary-core entry, DAIF left
 * masked until platform_irq_init()'s own enable_irq() call).
 */

    .section .text.boot, "ax"
    .global _start
    .type _start, %function
_start:
    msr     DAIFSet, #0xf
    /* GitHub issue #445: Aff0, not Aff1. This guard is what keeps main()
     * from running on a core that is not the primary, and it was still
     * carrying entry.S's Aff1 line -- the very line kernel_secondary_entry
     * below documents as wrong for this machine, because QEMU `virt`
     * numbers its cores in Aff0 and leaves Aff1 zero on every one of them.
     * So the guard read 0 for every core and parked none of them.
     *
     * Harmless today only because `-kernel` enters here on CPU 0 alone and
     * every other core waits in firmware for PSCI. It stops being harmless
     * the moment anything enters this symbol on a second core. */
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cbnz    x0, .Lpark

    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.hs    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:
    adrp    x0, boot_stack_top
    add     x0, x0, :lo12:boot_stack_top
    mov     sp, x0

    adrp    x0, el1_vectors
    add     x0, x0, :lo12:el1_vectors
    msr     vbar_el1, x0
    isb

    bl      el1_fpsimd_enable
    bl      kernel_mmu_init
    bl      main

.Lpark:
    wfe
    b       .Lpark

/* PSCI enters a successfully started secondary already in Non-secure EL1
 * on QEMU `virt` (same reasoning as _start above -- there is no EL2 drop
 * to do here either), with x0 carrying the caller-supplied context. */
    .global kernel_secondary_entry
kernel_secondary_entry:
    msr     DAIFSet, #0xf
    mov     x19, x0

    adrp    x0, secondary_stack_top
    add     x0, x0, :lo12:secondary_stack_top
    mov     sp, x0

    adrp    x0, el1_vectors
    add     x0, x0, :lo12:el1_vectors
    msr     vbar_el1, x0
    isb

    bl      el1_fpsimd_enable
    bl      kernel_mmu_init_secondary
    mov     x0, x19
    /* GitHub issue #445: the core index used to be extracted here, and
     * getting the field wrong was a real bug -- see cpu_id()'s comment in
     * kernel/platform/qemu/init.tkb, which now owns that knowledge for
     * both this file and its RPi5 counterpart. Nothing about which
     * affinity field this machine numbers cores in is stated in assembly
     * any more. */
    bl      kernel_secondary_main
.Lsecondary_park:
    wfe
    b       .Lsecondary_park

/* el1_fpsimd_enable(): identical to entry.S's own copy -- permit ordinary
 * compiled code to use FP/SIMD if LLVM selects it. Duplicated rather than
 * shared across the two entry.S variants because there is no third file
 * both could `use`/include from at the assembly level without inventing
 * new build-system plumbing for two lines this small. */
    .global el1_fpsimd_enable
    .type el1_fpsimd_enable, %function
el1_fpsimd_enable:
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb
    ret
