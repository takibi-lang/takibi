/* SPDX-License-Identifier: MIT
 *
 * FP/SIMD-across-interrupt fixture for GitHub issue #223.
 *
 * kernel/arch/arm64/boot/entry.S's Current-EL-SPx IRQ entry now saves and
 * restores the full exception frame, q0-q31/FPSR/FPCR included. Nothing in
 * the IRQ-reachable call graph happens to use SIMD today, so a fixture that
 * merely held live q registers across an interrupt would pass with or
 * without that save -- it would prove the accidental absence, not the
 * guarantee. This file supplies the missing half: fpsimd_irq_clobber stands
 * in for the first IRQ-path function LLVM compiles with SIMD, deliberately
 * destroying every q register (and FPSR's cumulative bits) inside the
 * interrupt, so the frame is the only thing that can bring the interrupted
 * context's values back.
 *
 * The clobber is armed only for the duration of fpsimd_irq_probe(), which
 * kernel/platform/rpi5/init.tkb calls once during boot. Outside that window the hook
 * is three instructions (load flag, test, return) on the IRQ path.
 *
 * Everything here is assembly because the point is to hold values in the
 * architectural q registers across a wait loop -- a takibi/LLVM version
 * could not state that, and would be free to spill them to the stack, where
 * an unsaved frame would never have touched them.
 */

    .equ FPSIMD_PROBE_ARMED, 0
    .equ FPSIMD_PROBE_IRQS,  8

    .section .text, "ax"

/* fpsimd_irq_clobber(): called by el1_current_irq_entry after the exception
 * frame is saved and before dispatch. x0-x3 are already in the frame at that
 * point and no AAPCS contract is in effect, so clobbering all 32 q registers
 * (including the callee-saved lower halves of q8-q15) is safe exactly here
 * and would not be safe if this were called from compiled code instead. */
    .global fpsimd_irq_clobber
    .type fpsimd_irq_clobber, %function
fpsimd_irq_clobber:
    adrp    x0, fpsimd_probe_state
    add     x0, x0, :lo12:fpsimd_probe_state
    ldr     x1, [x0, #FPSIMD_PROBE_ARMED]
    cbz     x1, .Lclobber_done
    ldr     x1, [x0, #FPSIMD_PROBE_IRQS]
    add     x1, x1, #1
    str     x1, [x0, #FPSIMD_PROBE_IRQS]
    movi    v0.16b, #0xff
    movi    v1.16b, #0xff
    movi    v2.16b, #0xff
    movi    v3.16b, #0xff
    movi    v4.16b, #0xff
    movi    v5.16b, #0xff
    movi    v6.16b, #0xff
    movi    v7.16b, #0xff
    movi    v8.16b, #0xff
    movi    v9.16b, #0xff
    movi    v10.16b, #0xff
    movi    v11.16b, #0xff
    movi    v12.16b, #0xff
    movi    v13.16b, #0xff
    movi    v14.16b, #0xff
    movi    v15.16b, #0xff
    movi    v16.16b, #0xff
    movi    v17.16b, #0xff
    movi    v18.16b, #0xff
    movi    v19.16b, #0xff
    movi    v20.16b, #0xff
    movi    v21.16b, #0xff
    movi    v22.16b, #0xff
    movi    v23.16b, #0xff
    movi    v24.16b, #0xff
    movi    v25.16b, #0xff
    movi    v26.16b, #0xff
    movi    v27.16b, #0xff
    movi    v28.16b, #0xff
    movi    v29.16b, #0xff
    movi    v30.16b, #0xff
    movi    v31.16b, #0xff
    /* FPSR holds only cumulative status bits, so a failure to restore it
     * leaves stale flags rather than changing how later FP code behaves --
     * unlike FPCR, which this hook deliberately does not touch. */
    mov     x1, #0x1f          /* IDC|IXC|UFC|OFC|DZC|IOC, all sticky */
    msr     fpsr, x1
.Lclobber_done:
    ret

/* fpsimd_irq_probe() -> usize
 *
 * 0            every q register and FPSR survived at least one Current-EL
 *              IRQ that ran the clobber above
 * 1..64        that many 64-bit lanes of q0-q31 came back wrong
 * 0x100 | n    FPSR came back with stale bits (added to the lane count)
 * 0xffff       no interrupt arrived within one second, so nothing was
 *              proven; the ARM generic timer PPI ticks every 1/64 s once
 *              platform_irq_init() has run, so this means the interrupt
 *              path itself is broken, and the fixture reports failure
 *              rather than passing vacuously
 */
    .global fpsimd_irq_probe
    .type fpsimd_irq_probe, %function
fpsimd_irq_probe:
    adrp    x0, fpsimd_probe_state
    add     x0, x0, :lo12:fpsimd_probe_state
    adrp    x1, fpsimd_probe_pattern
    add     x1, x1, :lo12:fpsimd_probe_pattern

    /* pattern[i] = seed + i * 0x0101010101010101, distinct per lane so a
     * restore that swapped two registers fails the comparison too, and
     * never equal to the clobber's all-ones. */
    movz    x4, #0xa5a5, lsl #48
    movk    x4, #0x1234, lsl #32
    movk    x4, #0x5678, lsl #16
    movk    x4, #0x9abc
    movz    x5, #0x0101, lsl #48
    movk    x5, #0x0101, lsl #32
    movk    x5, #0x0101, lsl #16
    movk    x5, #0x0101
    mov     x3, #0
.Lpattern_fill:
    madd    x6, x3, x5, x4
    str     x6, [x1, x3, lsl #3]
    add     x3, x3, #1
    cmp     x3, #64
    b.lo    .Lpattern_fill

    str     xzr, [x0, #FPSIMD_PROBE_IRQS]
    mov     x2, #1
    str     x2, [x0, #FPSIMD_PROBE_ARMED]

    ldp     q0, q1, [x1, #0x000]
    ldp     q2, q3, [x1, #0x020]
    ldp     q4, q5, [x1, #0x040]
    ldp     q6, q7, [x1, #0x060]
    ldp     q8, q9, [x1, #0x080]
    ldp     q10, q11, [x1, #0x0a0]
    ldp     q12, q13, [x1, #0x0c0]
    ldp     q14, q15, [x1, #0x0e0]
    ldp     q16, q17, [x1, #0x100]
    ldp     q18, q19, [x1, #0x120]
    ldp     q20, q21, [x1, #0x140]
    ldp     q22, q23, [x1, #0x160]
    ldp     q24, q25, [x1, #0x180]
    ldp     q26, q27, [x1, #0x1a0]
    ldp     q28, q29, [x1, #0x1c0]
    ldp     q30, q31, [x1, #0x1e0]
    msr     fpsr, xzr

    /* Wait for a real interrupt, bounded by one second of CNTPCT_EL0. Only
     * general registers are touched from here until the q registers are
     * read back. */
    mrs     x7, cntfrq_el0
    mrs     x8, cntpct_el0
    add     x8, x8, x7
.Lwait_irq:
    ldr     x9, [x0, #FPSIMD_PROBE_IRQS]
    cbnz    x9, .Lwait_done
    mrs     x10, cntpct_el0
    cmp     x10, x8
    b.lo    .Lwait_irq
.Lwait_done:
    mrs     x11, fpsr
    str     xzr, [x0, #FPSIMD_PROBE_ARMED]

    adrp    x12, fpsimd_probe_observed
    add     x12, x12, :lo12:fpsimd_probe_observed
    stp     q0, q1, [x12, #0x000]
    stp     q2, q3, [x12, #0x020]
    stp     q4, q5, [x12, #0x040]
    stp     q6, q7, [x12, #0x060]
    stp     q8, q9, [x12, #0x080]
    stp     q10, q11, [x12, #0x0a0]
    stp     q12, q13, [x12, #0x0c0]
    stp     q14, q15, [x12, #0x0e0]
    stp     q16, q17, [x12, #0x100]
    stp     q18, q19, [x12, #0x120]
    stp     q20, q21, [x12, #0x140]
    stp     q22, q23, [x12, #0x160]
    stp     q24, q25, [x12, #0x180]
    stp     q26, q27, [x12, #0x1a0]
    stp     q28, q29, [x12, #0x1c0]
    stp     q30, q31, [x12, #0x1e0]

    cbz     x9, .Lprobe_no_irq
    mov     x3, #0
    mov     x13, #0
.Lcompare:
    ldr     x6, [x1, x3, lsl #3]
    ldr     x14, [x12, x3, lsl #3]
    cmp     x6, x14
    cinc    x13, x13, ne
    add     x3, x3, #1
    cmp     x3, #64
    b.lo    .Lcompare
    cbz     x11, .Lprobe_return
    add     x13, x13, #0x100
.Lprobe_return:
    mov     x0, x13
    ret
.Lprobe_no_irq:
    mov     x0, #0xffff
    ret

    .section .bss, "aw", %nobits
    .align 4
fpsimd_probe_state:
    .zero 16
fpsimd_probe_pattern:
    .zero 512
fpsimd_probe_observed:
    .zero 512
