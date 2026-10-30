/* SPDX-License-Identifier: MIT
 *
 * The caller's frame pointer and stack pointer, for GitHub issue #811's
 * irqsoff tracer (kernel/kernel/profile_session.tkb is the only caller).
 *
 * Assembly rather than .tkb because no .tkb code can name x29 or sp: the
 * compiler has no intrinsic for either, and the maintainer decided on
 * 2026-10-19 (issue #811) that this kernel issue adds none. Same shape as
 * pmu.S: each helper is one register move with no logic of its own. The
 * frame walk, its bounds and everything it decides stay in the .tkb caller.
 *
 * Both are leaf functions that never touch x29 or sp, so the values they
 * return are the CALLER's: x29 is the caller's canonical frame record
 * ([x29] = previous x29, [x29 + 8] = saved x30, under the kernel's
 * default frame-pointer contract), and sp is the caller's stack pointer, which
 * bounds that walk to the current kernel stack.
 *
 * No return_address() helper: in a leaf .S, x30 is only the return into
 * the caller itself, and the caller's frame record already gives the
 * return one level up, which is the address the tracer wants.
 */

    .section .text, "ax"

/* caller_frame_address() -> usize: the caller's x29. */
    .global caller_frame_address
    .type caller_frame_address, %function
caller_frame_address:
    mov     x0, x29
    ret

/* caller_stack_address() -> usize: the caller's sp. */
    .global caller_stack_address
    .type caller_stack_address, %function
caller_stack_address:
    mov     x0, sp
    ret
