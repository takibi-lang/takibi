/* EL1/EL0 transition and register-frame mechanics only. Syscall policy and
 * process lifetime remain in Takibi. run_initial_user returns to its EL1
 * caller after exit, so linear VM/page owners stay live on that call frame.
 */
    .include "kernel/arch/arm64/kernel/exception_context.inc"

    /* GitHub issue #228: the EL0 syscall-ABI test payload that used to
     * live here (initial_user_payload/_end) is now compiled from
     * kernel/arch/arm64/kernel/user_payload.tkb and
     * user_payload_asm.S, linked standalone into a flat binary
     * (user_payload.ld) and embedded into the kernel image with
     * embed_file -- see kernel/kernel/syscall.tkb's initial_user_load
     * and the Makefile's KERNEL_USER_PAYLOAD_BIN rule. */

    .section .text, "ax"
    .global user_code_sync
user_code_sync:
    mov     x3, x0
    add     x2, x0, x1
.Ldcache_sync:
    dc      cvau, x0
    add     x0, x0, #64
    cmp     x0, x2
    b.lo    .Ldcache_sync
    dsb     ish
    mov     x0, x3
.Licache_sync:
    ic      ivau, x0
    add     x0, x0, #64
    cmp     x0, x2
    b.lo    .Licache_sync
    dsb     ish
    isb
    ret

    .global run_initial_user
    .type run_initial_user, %function
run_initial_user:
    sub     sp, sp, #96
    stp     x19, x20, [sp, #0]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x25, x26, [sp, #48]
    stp     x27, x28, [sp, #64]
    stp     x29, x30, [sp, #80]
    /* GitHub issue #229: the same ELR_EL1/SPSR_EL1-vs-eret window
     * EXC_CONTEXT_RESTORE closes exists here too, and this path is reached
     * with DAIF.I unmasked -- kernel/platform/rpi5/intc.tkb's
     * platform_irq_init() runs its one global enable_irq() long before
     * kernel/platform/rpi5/init.tkb gets here. An interrupt between these three msr
     * instructions and the eret would return the EL0 image to EL1h, or to a
     * kernel .text address, instead of to x0. EL0's own interrupt state is
     * unaffected: it comes from the SPSR value written below, not from
     * PSTATE.DAIF at the eret. */
    msr     DAIFSet, #0x2
    msr     sp_el0, x1
    /* A new image must not inherit thread-local state from whichever EL0
     * image last returned through this shared entry path. Its C runtime
     * installs its own thread pointer during startup. */
    msr     tpidr_el0, xzr
    /* EL0t with IRQ delivery enabled. The Lower-EL IRQ vector saves the
     * complete context before any scheduler decision. */
    mov     x2, #0
    msr     spsr_el1, x2
    msr     elr_el1, x0
    eret

    .global el0_sync_entry
    .type el0_sync_entry, %function
el0_sync_entry:
    sub     sp, sp, #EXC_CONTEXT_SIZE
    EXC_CONTEXT_SAVE
    /* The user x29 is saved above and restored on return. Kernel callees
     * start at an explicit frame-chain boundary rather than inheriting a
     * user-controlled pointer into stale kernel-stack contents. */
    mov     x29, xzr

    /* Lower-EL synchronous exceptions are either SVC64 syscalls or, for the
     * bounded process-image stack reservation, a translation fault. Handle
     * the latter with IRQs still masked: page allocation and one PTE update
     * are non-blocking, and a scheduler switch cannot interpose between the
     * fault and retry. All other non-SVC exceptions retain the fail-stop
     * evidence path. */
.Lsyscall_dispatch:
    mrs     x0, esr_el1
    lsr     x1, x0, #26
    cmp     x1, #0x24          /* Data Abort taken without a change in EL */
    b.eq    .Ldata_abort
    cmp     x1, #0x15          /* SVC instruction execution in AArch64 */
    b.ne    .Lsync_fail

    /* GitHub issue #187: exception entry unconditionally masks DAIF, so
     * without this, any syscall whose handling reaches a real
     * interrupt_wait() (RP1 USB xHCI's disk I/O completion) blocks
     * forever -- its own xhci_irq_handler ISR can never be taken while I
     * is masked, so the paired wfe/sev never wakes. Safe to clear here:
     * a nested IRQ lands on this same SP_EL1 stack, strictly below this
     * frame, and el1_current_irq_entry's own save/restore does not touch
     * any state already saved above. .Lsyscall_resume's eret restores the
     * ORIGINAL captured SPSR_EL1 (including EL0's enabled IRQ state), and the
     * next exception entry re-masks DAIF regardless, so this only widens
     * the window during which THIS syscall's own handling can be
     * interrupted. */
    msr     DAIFClr, #0x2

    mrs     x0, esr_el1
    ldr     x1, [sp, #64]
    ldr     x2, [sp, #0]
    ldr     x3, [sp, #8]
    ldr     x4, [sp, #16]
    ldr     x5, [sp, #24]
    ldr     x6, [sp, #32]
    bl      kernel_syscall_dispatch
    mov     x6, x0
    mov     x7, x1
    cmp     x6, #1
    b.eq    .Lsyscall_resume
    cmp     x6, #2
    b.eq    .Lsyscall_exit
    cmp     x6, #3
    b.eq    .Lsyscall_clone_child
    cmp     x6, #4
    b.eq    .Lsyscall_clone_parent
    cmp     x6, #5
    b.eq    .Lsyscall_block
    cmp     x6, #6
    b.eq    .Lsyscall_wait_interrupt
    cmp     x6, #7
    b.eq    .Lsyscall_exec
    cmp     x6, #8
    b.eq    .Lsyscall_child_exec
    mov     x0, #8
    mov     x1, sp
    b       el1_exception_evidence_from_frame

.Ldata_abort:
    mrs     x1, far_el1
    bl      process_image_handle_data_abort
    cbz     x0, .Lsync_fail
    EXC_CONTEXT_RESTORE
    add     sp, sp, #EXC_CONTEXT_SIZE
    eret

.Lsync_fail:
    mov     x0, #8
    mov     x1, sp
    b       el1_exception_evidence_from_frame

.Lsyscall_clone_child:
    // GitHub issue #221 Step 4: moved to kernel_syscall_clone_child_return
    // (.tkb), which replaces the hand-written EXC_CONTEXT_SIZE-word copy
    // loop with slice_copy and ends by sharing kernel_syscall_resume_return.
    mov     x0, sp
    mov     x1, x7
    b       kernel_syscall_clone_child_return

.Lclone_context_fail:
    mov     x1, sp
    mov     x0, #8
    b       el1_exception_evidence_from_frame

.Lsyscall_clone_parent:
    // GitHub issue #221 Step 6: moved to kernel_syscall_clone_parent_return
    // (.tkb) -- this is the exact bug fixed in commit 8db27e3 (see that
    // function's own comment for why keeping parent_sp as a plain .tkb local
    // across the reap call, instead of a hand-picked register, matters).
    mov     x0, x7
    b       kernel_syscall_clone_parent_return

.Lsyscall_block:
    // GitHub issue #221 Step 2: moved to kernel_syscall_block_return (.tkb),
    // which ends in the single shared el0_context_resume/kernel_syscall_fail_stop
    // primitives above instead of hand-rolling the restore-and-eret sequence.
    mov     x0, sp
    b       kernel_syscall_block_return

.Lsyscall_wait_interrupt:
    /* Wait for an interrupt, then run this same syscall again --
     * .Lsyscall_dispatch reloads esr and every argument from the saved
     * frame, so a retry re-asks the question rather than resuming a
     * half-finished answer.
     *
     * interrupt_notify() emits SEV, so WFE retains an event that arrives
     * between the readiness check and entering the wait.
     *
     * GitHub issue #448: this is also what the kernel does when EVERY
     * process is blocked. It used to be reached only by a UART waiter with
     * nobody else to run, and was named for that; a wait4 that finds no
     * runnable successor now lands here too instead of fail-stopping,
     * which is why the name no longer says UART. It is this kernel's idle
     * loop, standing on whichever process asked last. */
    wfe
    b       .Lsyscall_dispatch

.Lsyscall_exec:
    // GitHub issue #221 Step 7: byte-identical to .Lsyscall_exit below --
    // neither calls any kernel_process_* logic that a second competing
    // write path could race with (unlike Steps 2-6), so there is no bug
    // class here for a .tkb migration to make unreachable. The one real
    // improvement available is deduplicating the two copies of this
    // sequence, which el1_return_from_syscall below does.
    mov     x0, x7
    b       el1_return_from_syscall

.Lsyscall_child_exec:
    // GitHub issue #221 Step 5: moved to kernel_syscall_child_exec_return
    // (.tkb) -- this is the exact bug fixed in commit 8db27e3 (see that
    // function's own comment for why the field-write-then-resume ordering
    // here matters).
    mov     x0, sp
    b       kernel_syscall_child_exec_return

.Lsyscall_resume:
    // GitHub issue #221 Step 3: moved to kernel_syscall_resume_return (.tkb).
    // Label kept (not renamed) since .Lsyscall_clone_child also branches here
    // directly to share the same resume-with-reschedule-check tail.
    mov     x0, sp
    mov     x1, x7
    b       kernel_syscall_resume_return

.Lsyscall_exit:
    mov     x0, x7
    // fall through

// The single shared "return to run_initial_user's EL1 caller" tail, reached
// by both .Lsyscall_exit (action 2: parent exit) and .Lsyscall_exec (action
// 7: parent-only execve pending) with x0 already set to the value each wants
// to return. Pops exactly the frame run_initial_user's own prologue pushed,
// so this must run on the same EL1 kernel stack that call was made from,
// which is always true here: nothing between el0_sync_entry and this point
// ever switches away from it.
el1_return_from_syscall:
    add     sp, sp, #EXC_CONTEXT_SIZE
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldp     x27, x28, [sp, #64]
    ldp     x29, x30, [sp, #80]
    add     sp, sp, #96
    ret

    .global el0_context_set_x0
el0_context_set_x0:
    str     x1, [x0, #EXC_CONTEXT_X0]
    ret

    .global el0_context_set_elr_el1
el0_context_set_elr_el1:
    str     x1, [x0, #EXC_CONTEXT_ELR_EL1]
    ret

    .global el0_context_set_sp_el0
el0_context_set_sp_el0:
    str     x1, [x0, #EXC_CONTEXT_SP_EL0]
    ret

    .global el0_context_set_tpidr_el0
el0_context_set_tpidr_el0:
    str     x1, [x0, #EXC_CONTEXT_TPIDR_EL0]
    ret

    .global el0_context_retry_syscall
el0_context_retry_syscall:
    ldr     x1, [x0, #EXC_CONTEXT_ELR_EL1]
    sub     x1, x1, #4
    str     x1, [x0, #EXC_CONTEXT_ELR_EL1]
    ret

// GitHub issue #221 Step 2+: the single shared consumer for every action tail
// that resumes some already-fully-populated EL0 frame (the current frame with
// only a few fields changed, or an entirely different process's saved frame).
// Every `.Lsyscall_*` tail that used to hand-roll `EXC_CONTEXT_RESTORE; add sp,
// sp, #EXC_CONTEXT_SIZE; eret` itself now instead tail-branches into a small
// .tkb function that ends by calling this -- there is exactly one place left
// in the whole kernel that performs this restore-and-eret sequence, so two
// different code paths can no longer race to set elr_el1/sp_el0 and have one
// silently undone by the other's unconditional reload (see commit 8db27e3's
// first bug for the failure mode this replaces).
//
// el0_context_resume itself is no longer hand-written here -- GitHub issue
// #227 item 1's follow-up generates it from kernel/arch/arm64/kernel/
// exception_frame.tkb's `exception_restore el0_context_resume { ... }`
// declaration (lib/llvm_gen.ml's gen_exception_restore). Its own critical
// ordering requirement carried over exactly: `msr DAIFSet` MUST precede
// `mov sp, x0`, not follow it -- `mov sp, x0` switches SP_EL1 to the frame
// being resumed, which on a scheduler switch is a DIFFERENT process's
// kernel stack, and an interrupt taken in the window before DAIF.I is
// masked would build its own exception frame below that new stack instead
// of below the one this syscall actually ran on. The extern fn declaration
// below (kernel/arch/arm64/kernel/user_entry_extern.tkb) is unchanged --
// that is still what lets ordinary .tkb code call it.

// The single shared fail-stop entry, replacing every hand-written
// `mov x0, #8; b el1_exception_evidence` pair at each .tkb-reachable action
// tail.  The .tkb ABI supplies its saved ExceptionFrame in x0; retain it in
// x1 while x0 becomes the vector slot. x0=8 matches el0_sync_entry's own vector-slot identification
// (el1_vectors installs the lower-EL AArch64 sync slot at x0=8, GitHub issue
// #227 item 3), so a fail-stop reached this way is indistinguishable in the
// recorded evidence from one reached directly out of el0_sync_entry.
    .global kernel_syscall_fail_stop
kernel_syscall_fail_stop:
    mov     x1, x0
    mov     x0, #8
    b       el1_exception_evidence_from_frame

    /* Takibi-owned deliberate debugger stop. The generated Current-EL sync
     * entry saves/restores ExceptionFrame; this helper only emits BRK. */
    .global kernel_ddb_breakpoint
    .global kernel_ddb_breakpoint_start
    .global kernel_ddb_breakpoint_end
    .type kernel_ddb_breakpoint, %function
kernel_ddb_breakpoint_start:
kernel_ddb_breakpoint:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    brk     #0x544b
    ldp     x29, x30, [sp], #16
    ret
kernel_ddb_breakpoint_end:
    .size kernel_ddb_breakpoint, .-kernel_ddb_breakpoint

    /* One faultable instruction for DDB memory inspection. The caller
     * publishes the exact expected FAR before entering. On a matching
     * Current-EL data abort, kernel_ddb_sync_dispatch replaces ELR with
     * kernel_ddb_memory_fault_return; exception restore then resumes at
     * the zero-result return below with the original x30 intact. */
    .global kernel_ddb_guarded_read_u8
kernel_ddb_guarded_read_u8:
    ldrb    w0, [x0]
    ret

    .global kernel_ddb_memory_fault_return
kernel_ddb_memory_fault_return:
    mov     x0, #0
    ret

    /* Non-resumable tail for every other generated Current-EL sync frame. */
    .global kernel_current_sync_fail_stop
kernel_current_sync_fail_stop:
    mov     x1, x0
    mov     x0, #0
    b       el1_exception_evidence_from_frame

    .global crash_snapshot_read_sp_el0
crash_snapshot_read_sp_el0:
    mrs     x0, sp_el0
    ret

/* The CURRENT (EL1) stack pointer, which no MRS reads -- SP is not a system
 * register.  A leaf with no frame, so SP here is still the caller's: the
 * return address is in x30 and nothing has been pushed. */
    .global kernel_stack_read_sp_el1
kernel_stack_read_sp_el1:
    mov     x0, sp
    ret

    .global crash_snapshot_read_tpidr_el0
crash_snapshot_read_tpidr_el0:
    mrs     x0, tpidr_el0
    ret

    .global crash_snapshot_read_ttbr0_el1
crash_snapshot_read_ttbr0_el1:
    mrs     x0, ttbr0_el1
    ret

    .global crash_snapshot_read_mpidr_el1
crash_snapshot_read_mpidr_el1:
    mrs     x0, mpidr_el1
    ret

// output[0..4] = ExceptionFrame's SP_EL0, ELR_EL1, SPSR_EL1, TPIDR_EL0.
// The offsets come from exception_context.inc's compiler-generated .equ
// constants, so this copies only the existing frame ABI rather than defining
// a second layout for debugger consumers.
    .global crash_snapshot_copy_saved_frame
crash_snapshot_copy_saved_frame:
    ldr     x2, [x0, #EXC_CONTEXT_SP_EL0]
    str     x2, [x1, #0]
    ldr     x2, [x0, #EXC_CONTEXT_ELR_EL1]
    str     x2, [x1, #8]
    ldr     x2, [x0, #EXC_CONTEXT_SPSR_EL1]
    str     x2, [x1, #16]
    ldr     x2, [x0, #EXC_CONTEXT_TPIDR_EL0]
    str     x2, [x1, #24]
    ret
