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
    mrs     x0, mpidr_el1
    lsr     x0, x0, #8
    and     x0, x0, #3
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
    /* GitHub issue #237: QEMU `virt`'s per-CPU MPIDR_EL1 numbering puts the
     * core index in Aff0 (bits[7:0]) -- confirmed by dumping this
     * machine's own generated DTB (cpu@0 reg=0, cpu@1 reg=1) -- unlike
     * entry.S's RPi5 copy, which reads Aff1 (bits[9:8]) because BCM2712
     * numbers cores there instead (matching kernel/init/main.tkb's own
     * psci_cpu_on(0x100, ...) target_affinity, Aff1=1). A first real boot
     * attempt under this port silently failed smp_bringup with this exact
     * line still copied from entry.S unchanged: PSCI reported CPU_ON
     * SUCCESS, but kernel_secondary_main's own core_id==1 guard never
     * matched, because Aff1 is 0 for every QEMU `virt` core.
     */
    mrs     x1, mpidr_el1
    and     x1, x1, #0xff
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
