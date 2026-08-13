/* The one exception-frame shape. Every EL1 exception entry that returns to
 * the interrupted context uses this layout: EL0 sync (syscalls), Lower-EL
 * IRQ, and Current-EL-SPx IRQ. A saved SP_EL1 points at offset zero, and the
 * frame contains every architectural value the scheduler must preserve before
 * selecting a different context -- x0-x30, SP_EL0, ELR_EL1, SPSR_EL1,
 * TPIDR_EL0, and the FP/SIMD state q0-q31 + FPSR + FPCR.
 *
 * The FP/SIMD half is not optional for any entry, including the Current-EL
 * one: kernel/arch/arm64/boot/entry.S enables FP/SIMD in CPACR_EL1 for
 * ordinary compiled code, LLVM does select q registers in kernel .tkb code,
 * and since issue #187 syscall handling runs with IRQs unmasked -- so EL1
 * kernel code holding live q registers can be interrupted. GitHub issue #223
 * removed the separate 272-byte general-registers-only Current-EL frame that
 * used to exist alongside this one; a second layout is exactly what let that
 * asymmetry go unnoticed, so there is deliberately only one now.
 *
 * GitHub issue #286: the EXC_CONTEXT_* offset constants below used to be
 * hand-written here too, duplicating kernel/arch/arm64/kernel/
 * exception_frame.tkb's ExceptionFrame struct layout -- exactly the
 * omission risk that let TPIDR_EL0 go missing from this file once already
 * (see that struct's own comment). scripts/gen_exception_frame.py now
 * computes exception_context_offsets.inc's .equ constants from the struct
 * directly, so this file no longer states them independently; it only
 * `.include`s the generated result and keeps the hand-written SAVE/RESTORE
 * macro bodies below as ordinary tracked source (never generated, never
 * gitignored -- there is exactly one copy of this assembly, and it lives
 * in git history like any other source file).
 *
 * Every register/system-register slot below is addressed through its
 * EXC_CONTEXT_* symbol, never a raw hex literal: a 2026-08-13 post-mortem
 * on the #286 fix found the macros still spelling most x0-x29/q0-q31
 * offsets as bare hex (`[sp, #0x030]`), so a future struct field reorder
 * would silently desync those literals from the regenerated offsets file
 * with nothing to catch it -- the offsets generator updates the .equ
 * values, but a stp/ldp still holding stale hex would keep reading and
 * writing the OLD slot. Routing every reference through its symbol makes
 * the assembler itself the check: a mismatched or removed field fails to
 * assemble instead of silently drifting.
 */
    .include "kernel/arch/arm64/kernel/exception_context_offsets.inc"

.macro EXC_CONTEXT_SAVE
    stp     x0, x1, [sp, #EXC_CONTEXT_X0]
    stp     x2, x3, [sp, #EXC_CONTEXT_X2]
    stp     x4, x5, [sp, #EXC_CONTEXT_X4]
    stp     x6, x7, [sp, #EXC_CONTEXT_X6]
    stp     x8, x9, [sp, #EXC_CONTEXT_X8]
    stp     x10, x11, [sp, #EXC_CONTEXT_X10]
    stp     x12, x13, [sp, #EXC_CONTEXT_X12]
    stp     x14, x15, [sp, #EXC_CONTEXT_X14]
    stp     x16, x17, [sp, #EXC_CONTEXT_X16]
    stp     x18, x19, [sp, #EXC_CONTEXT_X18]
    stp     x20, x21, [sp, #EXC_CONTEXT_X20]
    stp     x22, x23, [sp, #EXC_CONTEXT_X22]
    stp     x24, x25, [sp, #EXC_CONTEXT_X24]
    stp     x26, x27, [sp, #EXC_CONTEXT_X26]
    stp     x28, x29, [sp, #EXC_CONTEXT_X28]
    mrs     x9, sp_el0
    stp     x30, x9, [sp, #EXC_CONTEXT_X30]
    mrs     x9, elr_el1
    mrs     x10, spsr_el1
    stp     x9, x10, [sp, #EXC_CONTEXT_ELR_EL1]
    stp     q0, q1, [sp, #EXC_CONTEXT_Q0]
    stp     q2, q3, [sp, #EXC_CONTEXT_Q2]
    stp     q4, q5, [sp, #EXC_CONTEXT_Q4]
    stp     q6, q7, [sp, #EXC_CONTEXT_Q6]
    stp     q8, q9, [sp, #EXC_CONTEXT_Q8]
    stp     q10, q11, [sp, #EXC_CONTEXT_Q10]
    stp     q12, q13, [sp, #EXC_CONTEXT_Q12]
    stp     q14, q15, [sp, #EXC_CONTEXT_Q14]
    stp     q16, q17, [sp, #EXC_CONTEXT_Q16]
    stp     q18, q19, [sp, #EXC_CONTEXT_Q18]
    stp     q20, q21, [sp, #EXC_CONTEXT_Q20]
    stp     q22, q23, [sp, #EXC_CONTEXT_Q22]
    stp     q24, q25, [sp, #EXC_CONTEXT_Q24]
    stp     q26, q27, [sp, #EXC_CONTEXT_Q26]
    stp     q28, q29, [sp, #EXC_CONTEXT_Q28]
    stp     q30, q31, [sp, #EXC_CONTEXT_Q30]
    mrs     x9, fpsr
    mrs     x10, fpcr
    str     x9, [sp, #EXC_CONTEXT_FPSR]
    str     x10, [sp, #EXC_CONTEXT_FPCR]
    mrs     x9, tpidr_el0
    str     x9, [sp, #EXC_CONTEXT_TPIDR_EL0]
.endm

/* GitHub issue #229: DAIF.I must be masked for the whole restore-and-eret
 * sequence. ELR_EL1/SPSR_EL1 are architectural exception-return state, not
 * ordinary registers: taking ANY exception between loading them here and the
 * eret overwrites both with the interrupting context's own values, and the
 * interrupt handler's own restore puts back what IT saved -- the kernel PC
 * and EL1h -- discarding what this sequence just loaded. The eret then
 * returns to the wrong place. Both halves of the window are fatal:
 *
 *   - Interrupted between the two msr instructions below: ELR_EL1 is left
 *     pointing at the `msr spsr_el1` instruction itself while that
 *     instruction then goes on to install the frame's genuine EL0 SPSR, so
 *     the eret drops to EL0 *at a kernel .text address*.
 *   - Interrupted anywhere after both msr instructions: ELR_EL1/SPSR_EL1
 *     both stay clobbered, so the eret jumps back into this restore sequence
 *     at EL1h and loops on itself, re-adding EXC_CONTEXT_SIZE to sp each
 *     pass until an unrelated EL1 fault stops it.
 *
 * Every entry that uses this macro reaches it with DAIF.I already masked
 * today EXCEPT the syscall path, which unmasks it deliberately (see
 * kernel/arch/arm64/kernel/user_entry.S's issue #187 comment) -- that is
 * where the ~25-40%-of-boots intermittent fail-stop came from. Masking here,
 * in the one shared restore shape rather than at each of its callers, is
 * what keeps a future path that unmasks DAIF.I mid-handler (exactly what
 * #187 did) from silently reopening the same window. Re-masking on the paths
 * that were already masked is a no-op; the eret restores PSTATE.DAIF from
 * SPSR_EL1 regardless, so this never changes the interrupted context's own
 * interrupt state. */
.macro EXC_CONTEXT_RESTORE
    msr     DAIFSet, #0x2
    ldp     x9, x10, [sp, #EXC_CONTEXT_ELR_EL1]
    msr     elr_el1, x9
    msr     spsr_el1, x10
    ldr     x9, [sp, #EXC_CONTEXT_SP_EL0]
    msr     sp_el0, x9
    ldp     q0, q1, [sp, #EXC_CONTEXT_Q0]
    ldp     q2, q3, [sp, #EXC_CONTEXT_Q2]
    ldp     q4, q5, [sp, #EXC_CONTEXT_Q4]
    ldp     q6, q7, [sp, #EXC_CONTEXT_Q6]
    ldp     q8, q9, [sp, #EXC_CONTEXT_Q8]
    ldp     q10, q11, [sp, #EXC_CONTEXT_Q10]
    ldp     q12, q13, [sp, #EXC_CONTEXT_Q12]
    ldp     q14, q15, [sp, #EXC_CONTEXT_Q14]
    ldp     q16, q17, [sp, #EXC_CONTEXT_Q16]
    ldp     q18, q19, [sp, #EXC_CONTEXT_Q18]
    ldp     q20, q21, [sp, #EXC_CONTEXT_Q20]
    ldp     q22, q23, [sp, #EXC_CONTEXT_Q22]
    ldp     q24, q25, [sp, #EXC_CONTEXT_Q24]
    ldp     q26, q27, [sp, #EXC_CONTEXT_Q26]
    ldp     q28, q29, [sp, #EXC_CONTEXT_Q28]
    ldp     q30, q31, [sp, #EXC_CONTEXT_Q30]
    ldr     x9, [sp, #EXC_CONTEXT_FPSR]
    ldr     x10, [sp, #EXC_CONTEXT_FPCR]
    msr     fpsr, x9
    msr     fpcr, x10
    ldr     x9, [sp, #EXC_CONTEXT_TPIDR_EL0]
    msr     tpidr_el0, x9
    ldp     x0, x1, [sp, #EXC_CONTEXT_X0]
    ldp     x2, x3, [sp, #EXC_CONTEXT_X2]
    ldp     x4, x5, [sp, #EXC_CONTEXT_X4]
    ldp     x6, x7, [sp, #EXC_CONTEXT_X6]
    ldp     x8, x9, [sp, #EXC_CONTEXT_X8]
    ldp     x10, x11, [sp, #EXC_CONTEXT_X10]
    ldp     x12, x13, [sp, #EXC_CONTEXT_X12]
    ldp     x14, x15, [sp, #EXC_CONTEXT_X14]
    ldp     x16, x17, [sp, #EXC_CONTEXT_X16]
    ldp     x18, x19, [sp, #EXC_CONTEXT_X18]
    ldp     x20, x21, [sp, #EXC_CONTEXT_X20]
    ldp     x22, x23, [sp, #EXC_CONTEXT_X22]
    ldp     x24, x25, [sp, #EXC_CONTEXT_X24]
    ldp     x26, x27, [sp, #EXC_CONTEXT_X26]
    ldp     x28, x29, [sp, #EXC_CONTEXT_X28]
    ldp     x30, xzr, [sp, #EXC_CONTEXT_X30]
.endm
