/* SPDX-License-Identifier: MIT
 * Thin RPi5 boot shim for issue #177. TF-A hands off at EL2; this file does
 * the system-register work Takibi cannot express and drops exactly once to
 * the monolithic EL1 kernel. It is not an EL2 service layer.
 */
    .section .text.boot, "ax"
    .global _start
    .type _start, %function
_start:
    mrs     x0, mpidr_el1
    lsr     x0, x0, #8
    and     x0, x0, #3
    cbnz    x0, .Lpark

    adrp    x0, boot_stack_top
    add     x0, x0, :lo12:boot_stack_top
    mov     sp, x0

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
    /* EL1 may use the physical counter/timer without trapping to EL2. */
    mrs     x0, cnthctl_el2
    orr     x0, x0, #3
    msr     cnthctl_el2, x0

    /* EL1 and EL0 execute AArch64; retain all unrelated inherited bits. */
    mrs     x0, hcr_el2
    orr     x0, x0, #(1 << 31)
    msr     hcr_el2, x0

    adrp    x0, el1_vectors
    add     x0, x0, :lo12:el1_vectors
    msr     vbar_el1, x0

    adrp    x0, boot_stack_top
    add     x0, x0, :lo12:boot_stack_top
    msr     sp_el1, x0

    mov     x0, #0x3c5         /* EL1h, DAIF masked */
    msr     spsr_el2, x0
    adr     x0, .Lel1_entry
    msr     elr_el2, x0
    isb
    eret

.Lel1_entry:
    /* Permit ordinary compiled code to use FP/SIMD if LLVM selects it. */
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb
    bl      kernel_mmu_init
    bl      main

.Lpark:
    wfe
    b       .Lpark

/* All sixteen architectural vector slots lead to an evidence-preserving
 * fail-stop path except slot 8 (lower-EL AArch64 sync, EL0 syscalls) and
 * slots 5/9 (Current-EL SPx IRQ and Lower-EL AArch64 IRQ, GitHub issue
 * #187). x16 identifies the slot for the ones that still fail-stop. No slot
 * silently spins at an anonymous PC. Slots 5 and 9 both branch to the same
 * el1_irq_entry: EL1h always uses SP_EL1 for a taken exception regardless
 * of which EL it interrupted, so one generic frame-save/dispatch/restore
 * stub correctly handles an interrupt arriving either while this kernel's
 * own EL1 code runs (slot 5) or while an EL0 process is actually executing
 * (slot 9) -- see kernel/platform/rpi5/intc.tkb's header comment.
 */
    .section .text.vectors, "ax"
    .align 11
el1_vectors:
.macro VECTOR slot
    mov     x16, #\slot
    b       el1_exception_evidence
    .align  7
.endm
    VECTOR 0
    VECTOR 1
    VECTOR 2
    VECTOR 3
    VECTOR 4
    b       el1_irq_entry
    .align  7
    VECTOR 6
    VECTOR 7
    mov     x16, #8
    b       el0_sync_entry
    .align  7
    b       el1_irq_entry
    .align  7
    VECTOR 10
    VECTOR 11
    VECTOR 12
    VECTOR 13
    VECTOR 14
    VECTOR 15

    .section .text, "ax"
    .global el1_exception_evidence
el1_exception_evidence:
    adrp    x17, exception_vector_slot
    add     x17, x17, :lo12:exception_vector_slot
    str     x16, [x17]
    mrs     x16, esr_el1
    str     x16, [x17, #8]
    mrs     x16, far_el1
    str     x16, [x17, #16]
    mrs     x16, elr_el1
    str     x16, [x17, #24]
    mrs     x16, spsr_el1
    str     x16, [x17, #32]
.Levidence_park:
    wfe
    b       .Levidence_park

/* enable_irq()/disable_irq(): DAIF.I-only mask, matching
 * examples/common_rpi5/startup.S's spelling. kernel/platform/rpi5/intc.tkb's
 * platform_irq_init() calls enable_irq() once all GIC/MIP0/MSI-X routing for
 * every currently-handled source is configured; UART0's PL011 peripheral
 * itself stays source-masked (IMSC=0) until kernel/init/main.tkb's later
 * irq_uart_rx_unmask() call, so no UART interrupt can actually arrive before
 * then even though DAIF.I is already clear. */
    .global enable_irq
enable_irq:
    msr     DAIFClr, #0x2
    ret

    .global disable_irq
disable_irq:
    msr     DAIFSet, #0x2
    ret

/* Full x0-x30 + ELR_EL1/SPSR_EL1 save/restore around rpi5_irq_dispatch,
 * the Current-EL-SPx IRQ handler for GitHub issue #187. Same 272-byte frame
 * shape as examples/common_rpi5/startup.S's rpi5_irq_entry, adapted to
 * EL1's own elr_el1/spsr_el1 since this kernel (unlike examples/common_rpi5)
 * runs its own code at EL1, not EL2. */
    .global el1_irq_entry
el1_irq_entry:
    sub     sp,  sp,  #272
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  x9,  [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    stp     x30, xzr, [sp, #240]
    mrs     x0,  elr_el1
    mrs     x1,  spsr_el1
    stp     x0,  x1,  [sp, #256]

    mov     x0, sp
    bl      rpi5_irq_dispatch
    mov     sp, x0

    ldp     x0,  x1,  [sp, #256]
    msr     elr_el1,  x0
    msr     spsr_el1, x1
    ldp     x0,  x1,  [sp, #0]
    ldp     x2,  x3,  [sp, #16]
    ldp     x4,  x5,  [sp, #32]
    ldp     x6,  x7,  [sp, #48]
    ldp     x8,  x9,  [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldp     x30, xzr, [sp, #240]
    add     sp,  sp,  #272
    eret

    .section .bss, "aw", %nobits
    .align 3
    .global exception_vector_slot
exception_vector_slot:
    .zero 40
