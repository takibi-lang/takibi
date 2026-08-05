/* SPDX-License-Identifier: MIT
 * Thin RPi5 boot shim for issue #177. TF-A hands off at EL2; this file does
 * the system-register work Takibi cannot express and drops exactly once to
 * the monolithic EL1 kernel. It is not an EL2 service layer.
 */
    .include "kernel/arch/arm64/kernel/exception_context.inc"

    .section .text.boot, "ax"
    .global _start
    .type _start, %function
_start:
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
    adr     x1, .Lel1_entry
    bl      el2_drop_to_el1

.Lel1_entry:
    bl      el1_fpsimd_enable
    bl      kernel_mmu_init
    bl      main

.Lpark:
    wfe
    b       .Lpark

/* PSCI enters a successfully started secondary in Non-secure EL2 with x0
 * carrying the caller-supplied context. Unlike the JTAG loader, this path is
 * equally usable when the same image is later loaded from SD/USB/network. */
    .global kernel_secondary_entry
kernel_secondary_entry:
    msr     DAIFSet, #0xf
    mov     x19, x0

    adrp    x0, secondary_stack_top
    add     x0, x0, :lo12:secondary_stack_top
    adr     x1, .Lsecondary_el1
    bl      el2_drop_to_el1

.Lsecondary_el1:
    bl      el1_fpsimd_enable
    bl      kernel_mmu_init_secondary
    mov     x0, x19
    mrs     x1, mpidr_el1
    ubfx    x1, x1, #8, #2
    bl      kernel_secondary_main
.Lsecondary_park:
    wfe
    b       .Lsecondary_park

/* el2_drop_to_el1(stack_top: x0, el1_entry: x1): the EL2 configuration and
 * drop-to-EL1 sequence shared by _start and kernel_secondary_entry (GitHub
 * issue #224) -- previously duplicated register-for-register between the
 * primary and secondary boot paths, with nothing keeping the two copies in
 * sync. Configures physical counter/timer trapping, EL1/EL0 execution
 * state, the one shared vector table, and the caller's own stack (as both
 * the live EL2 SP and SP_EL1), then erets to el1_entry in EL1h with DAIF
 * masked. Never returns -- the caller's `bl` return address is unused,
 * matching how .Lel1_entry/.Lsecondary_el1 are reached below. */
    .global el2_drop_to_el1
    .type el2_drop_to_el1, %function
el2_drop_to_el1:
    mov     sp, x0

    /* EL1 may use the physical counter/timer without trapping to EL2. */
    mrs     x2, cnthctl_el2
    orr     x2, x2, #3
    msr     cnthctl_el2, x2

    /* EL1 and EL0 execute AArch64; retain all unrelated inherited bits. */
    mrs     x2, hcr_el2
    orr     x2, x2, #(1 << 31)
    msr     hcr_el2, x2

    adrp    x2, el1_vectors
    add     x2, x2, :lo12:el1_vectors
    msr     vbar_el1, x2
    msr     sp_el1, x0

    mov     x2, #0x3c5          /* EL1h, DAIF masked */
    msr     spsr_el2, x2
    msr     elr_el2, x1
    isb
    eret

/* el1_fpsimd_enable(): permit ordinary compiled code to use FP/SIMD if LLVM
 * selects it. Shared by .Lel1_entry and .Lsecondary_el1 (GitHub issue #224)
 * -- both used to set CPACR_EL1 separately, right after their own EL2->EL1
 * drop. */
    .global el1_fpsimd_enable
    .type el1_fpsimd_enable, %function
el1_fpsimd_enable:
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb
    ret

    .global psci_cpu_on
psci_cpu_on: /* fn(target_affinity, entry, context) -> usize */
    mov     x3, x2
    mov     x2, x1
    mov     x1, x0
    movz    x0, #0x0003
    movk    x0, #0xc400, lsl #16
    smc     #0
    ret

    .global kernel_secondary_entry_address
kernel_secondary_entry_address:
    adrp    x0, kernel_secondary_entry
    add     x0, x0, :lo12:kernel_secondary_entry
    ret

/* All sixteen architectural vector slots lead to an evidence-preserving
 * fail-stop path except slot 8 (lower-EL AArch64 sync, EL0 syscalls) and
 * slots 5/9 (Current-EL SPx IRQ and Lower-EL AArch64 IRQ). x16 identifies
 * the slot for the ones that still fail-stop. No slot silently spins at an
 * anonymous PC. Slots 5 and 9 stay separate entry points because only the
 * Lower-EL one (slot 9) may select another process from its returned frame
 * SP, but both build the single exception frame declared in
 * kernel/arch/arm64/kernel/exception_context.inc -- the same one the
 * syscall path uses.
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
    b       el1_current_irq_entry
    .align  7
    VECTOR 6
    VECTOR 7
    mov     x16, #8
    b       el0_sync_entry
    .align  7
    b       el0_irq_entry
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

/* Current-EL-SPx IRQ entry (GitHub issue #187): an interrupt taken while
 * this kernel's own EL1 code runs, e.g. during a syscall that has already
 * unmasked DAIF.I. It saves and restores the same complete
 * exception frame as the two EL0-facing entries below -- including q0-q31,
 * FPSR and FPCR, which the earlier hand-written 272-byte
 * general-registers-only frame here did not (GitHub issue #223). The
 * interrupted EL1 code can hold live q registers, so anything this vector
 * reaches that LLVM compiles with SIMD would otherwise corrupt them.
 *
 * fpsimd_irq_clobber is the fixture hook that keeps that guarantee honest:
 * it is inert unless kernel/arch/arm64/kernel/fpsimd_probe.S's probe has
 * armed it, and it runs here -- after the frame is saved, before any
 * dispatch -- where no AAPCS caller/callee register contract exists yet to
 * violate. SP_EL0 is saved and restored too; at EL1h it is not the running
 * stack pointer, so that is a faithful round trip of the EL0 process's own
 * value. */
    .global el1_current_irq_entry
el1_current_irq_entry:
    sub     sp, sp, #EXC_CONTEXT_SIZE
    EXC_CONTEXT_SAVE

    bl      fpsimd_irq_clobber

    mov     x0, sp
    bl      rpi5_irq_dispatch
    mov     sp, x0

    EXC_CONTEXT_RESTORE
    add     sp, sp, #EXC_CONTEXT_SIZE
    eret

/* Lower-EL AArch64 IRQ entry, the same frame again -- here it is also a
 * complete resumable EL0 context. rpi5_irq_dispatch still returns the
 * same SP in this milestone; a later issue #188 step may select another
 * process by returning its saved frame SP. */
    .global el0_irq_entry
el0_irq_entry:
    sub     sp, sp, #EXC_CONTEXT_SIZE
    EXC_CONTEXT_SAVE

    mov     x0, sp
    bl      rpi5_el0_irq_dispatch
    mov     sp, x0

    EXC_CONTEXT_RESTORE
    add     sp, sp, #EXC_CONTEXT_SIZE
    eret

    .section .bss, "aw", %nobits
    .align 3
    .global exception_vector_slot
exception_vector_slot:
    .zero 40
