/* EL1/EL0 transition and register-frame mechanics only. Syscall policy and
 * process lifetime remain in Takibi. run_initial_user returns to its EL1
 * caller after exit, so linear VM/page owners stay live on that call frame.
 */
    .include "kernel/arch/arm64/kernel/user_context.inc"

    .section .rodata, "a"
    .align 4
initial_user_payload:
    /* write(9, ..., 1) must return -EBADF. */
    adr     x1, .Luser_message
    mov     x2, #1
    mov     x0, #9
    mov     x8, #64
    svc     #0
    mov     x9, #-9
    cmp     x0, x9
    b.ne    .Luser_fail

    /* write(1, null, 1) must return -EFAULT. */
    mov     x0, #1
    mov     x1, #0
    mov     x2, #1
    mov     x8, #64
    svc     #0
    mov     x9, #-14
    cmp     x0, x9
    b.ne    .Luser_fail

    /* openat/write/close /mutable.txt through the Linux file ABI. */
    mov     x0, #0
    adr     x1, .Lmutable_path
    mov     x2, #1
    mov     x8, #56
    svc     #0
    cmp     x0, #3
    b.ne    .Luser_fail
    mov     x0, #3
    adr     x1, .Lmutable_content
    mov     x2, #7
    mov     x8, #64
    svc     #0
    cmp     x0, #7
    b.ne    .Luser_fail
    mov     x0, #3
    mov     x8, #57
    svc     #0
    cbnz    x0, .Luser_fail

    /* socket/bind/listen/close one IPv4 stream endpoint. */
    mov     x0, #2
    mov     x1, #1
    mov     x2, #0
    mov     x8, #198
    svc     #0
    cmp     x0, #4
    b.ne    .Luser_fail
    mov     x0, #4
    adr     x1, .Lsocket_address
    mov     x2, #16
    mov     x8, #200
    svc     #0
    cbnz    x0, .Luser_fail
    mov     x0, #4
    mov     x1, #1
    mov     x8, #201
    svc     #0
    cbnz    x0, .Luser_fail
    mov     x0, #4
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    mov     x8, #242
    svc     #0
    cmp     x0, #5
    b.ne    .Luser_fail
    /* Issue #189: accept a second stream while fd 5 remains live. The
     * bounded fd/connection pools must allocate an independent fd 6/slot. */
    mov     x0, #4
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    mov     x8, #242
    svc     #0
    cmp     x0, #6
    b.ne    .Luser_fail
    sub     sp, sp, #32
    mov     x0, #5
    mov     x1, sp
    mov     x2, #8
    mov     x8, #63
    svc     #0
    cmp     x0, #8
    b.ne    .Luser_fail
    mov     x0, #6
    add     x1, sp, #16
    mov     x2, #8
    mov     x8, #63
    svc     #0
    cmp     x0, #8
    b.ne    .Luser_fail
    mov     x0, #6
    adr     x1, .Lconnection_b_response
    mov     x2, #8
    mov     x8, #64
    svc     #0
    cmp     x0, #8
    b.ne    .Luser_fail
    mov     x0, #5
    add     x1, sp, #8
    mov     x2, #8
    mov     x8, #63
    svc     #0
    cmp     x0, #8
    b.ne    .Luser_fail
    mov     x0, #5
    adr     x1, .Lsocket_response
    mov     x2, #19
    mov     x8, #64
    svc     #0
    cmp     x0, #19
    b.ne    .Luser_fail
    mov     x0, #5
    adr     x1, .Llarge_socket_response
    mov     x2, #1461
    mov     x8, #64
    svc     #0
    cmp     x0, #1460
    b.ne    .Luser_fail
    mov     x0, #5
    adr     x1, .Llarge_socket_response
    add     x1, x1, #1460
    mov     x2, #1
    mov     x8, #64
    svc     #0
    cmp     x0, #1
    b.ne    .Luser_fail
    add     sp, sp, #32
    mov     x0, #6
    mov     x8, #57
    svc     #0
    cbnz    x0, .Luser_fail
    mov     x0, #5
    mov     x8, #57
    svc     #0
    cbnz    x0, .Luser_fail
    mov     x0, #4
    mov     x8, #57
    svc     #0
    cbnz    x0, .Luser_fail

    /* The focused context fixture clones only after its independent socket
     * lifecycle is complete; the real HTTPd daemon covers fd inheritance. */
    mov     x0, #0x11
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    mov     x4, #0
    mov     x8, #220
    svc     #0
    cbz     x0, .Lclone_child
    cmp     x0, #2
    b.ne    .Luser_fail
    b       .Lclone_parent_done
.Lclone_child:
    /* The first byte must take the scheduler-aware Blocked -> Ready path.
     * Later bytes may already be in the bounded RX ring when selected. */
    adr     x24, .Luart_fixture
    mov     x25, #0
.Luart_wait_loop:
    mov     x8, #451
    svc     #0
    ldrb    w10, [x24, x25]
    cmp     w0, w10
    b.ne    .Luser_fail
    add     x25, x25, #1
    cmp     x25, #8
    b.ne    .Luart_wait_loop
    /* Scheduler acceptance: private same-VA data plus GPR and SIMD
     * signatures must survive involuntary timer preemption. */
    movz    x9, #0x1000
    movk    x9, #0x4000, lsl #16
    mov     w10, #0x22
    strb    w10, [x9]
    movz    x19, #0xdef0
    movk    x19, #0x9abc, lsl #16
    movk    x19, #0x5678, lsl #32
    movk    x19, #0x1234, lsl #48
    mov     x22, sp
    movi    v8.16b, #0x5a
    movz    x9, #0xc200
    movk    x9, #0x0beb, lsl #16
.Lclone_child_compute:
    subs    x9, x9, #1
    b.ne    .Lclone_child_compute
    movz    x20, #0xdef0
    movk    x20, #0x9abc, lsl #16
    movk    x20, #0x5678, lsl #32
    movk    x20, #0x1234, lsl #48
    cmp     x19, x20
    b.ne    .Lscheduler_child_gpr_fail
    mov     x23, sp
    cmp     x22, x23
    b.ne    .Lscheduler_child_sp_fail
    umov    x10, v8.d[0]
    movz    x11, #0x5a5a
    movk    x11, #0x5a5a, lsl #16
    movk    x11, #0x5a5a, lsl #32
    movk    x11, #0x5a5a, lsl #48
    cmp     x10, x11
    b.ne    .Lscheduler_child_simd_fail
    movz    x9, #0x1000
    movk    x9, #0x4000, lsl #16
    ldrb    w10, [x9]
    cmp     w10, #0x22
    b.ne    .Lscheduler_child_asid_fail
    mov     x0, #42
    mov     x8, #93
    svc     #0
.Lclone_parent_done:
    movz    x9, #0x1000
    movk    x9, #0x4000, lsl #16
    mov     w10, #0x11
    strb    w10, [x9]
    movz    x19, #0xdef0
    movk    x19, #0x9abc, lsl #16
    movk    x19, #0x5678, lsl #32
    movk    x19, #0x1234, lsl #48
    mov     x22, sp
    movi    v8.16b, #0xa5
    movz    x9, #0x8400
    movk    x9, #0x17d7, lsl #16
.Lclone_parent_compute:
    subs    x9, x9, #1
    b.ne    .Lclone_parent_compute
    movz    x20, #0xdef0
    movk    x20, #0x9abc, lsl #16
    movk    x20, #0x5678, lsl #32
    movk    x20, #0x1234, lsl #48
    cmp     x19, x20
    b.ne    .Lscheduler_parent_gpr_fail
    mov     x23, sp
    cmp     x22, x23
    b.ne    .Lscheduler_parent_sp_fail
    umov    x10, v8.d[0]
    movz    x11, #0xa5a5
    movk    x11, #0xa5a5, lsl #16
    movk    x11, #0xa5a5, lsl #32
    movk    x11, #0xa5a5, lsl #48
    cmp     x10, x11
    b.ne    .Lscheduler_parent_simd_fail
    movz    x9, #0x1000
    movk    x9, #0x4000, lsl #16
    ldrb    w10, [x9]
    cmp     w10, #0x11
    b.ne    .Lscheduler_parent_asid_fail

    /* Accepted only if this parent reached the end of its compute section
     * while the child is still Blocked on UART RX. */
    mov     x8, #452
    svc     #0
    cbnz    x0, .Luser_fail

    /* Keep the independently-running parent live while the host observes the
     * progress marker and delivers UART input. Timer preemption then selects
     * the child after the IRQ changes it from Blocked to Ready. */
    movz    x9, #0x8400
    movk    x9, #0x17d7, lsl #16
.Lclone_parent_after_progress:
    subs    x9, x9, #1
    b.ne    .Lclone_parent_after_progress

    adr     x1, .Luser_message
    mov     x2, #21
    mov     x0, #1
    mov     x8, #64
    svc     #0
    cmp     x0, #21
    b.ne    .Luser_fail
    mov     x0, #0
    mov     x8, #93
    svc     #0
.Luser_fail:
    b       .Luser_fail
.Lscheduler_child_gpr_fail:
    b       .Lscheduler_child_gpr_fail
.Lscheduler_child_simd_fail:
    b       .Lscheduler_child_simd_fail
.Lscheduler_child_sp_fail:
    b       .Lscheduler_child_sp_fail
.Lscheduler_child_asid_fail:
    b       .Lscheduler_child_asid_fail
.Lscheduler_parent_gpr_fail:
    b       .Lscheduler_parent_gpr_fail
.Lscheduler_parent_simd_fail:
    b       .Lscheduler_parent_simd_fail
.Lscheduler_parent_sp_fail:
    b       .Lscheduler_parent_sp_fail
.Lscheduler_parent_asid_fail:
    b       .Lscheduler_parent_asid_fail
.Luser_message:
    .ascii  "hello from userspace\n"
.Lmutable_path:
    .asciz  "/mutable.txt"
.Lmutable_content:
    .ascii  "el0-ok\n"
.Luart_fixture:
    .ascii  "irqtest\n"
    .balign 2
.Lsocket_address:
    .hword  2
    .byte   0x1f, 0x90
    .word   0
    .quad   0
.Lsocket_response:
    .ascii  "HTTP/1.0 200 OK\r\n\r\n"
.Lconnection_b_response:
    .ascii  "conn-B\n!"
.Llarge_socket_response:
    .fill   1461, 1, 0x5a
initial_user_payload_end:

    .section .text, "ax"
    .global initial_user_payload_addr
initial_user_payload_addr:
    adrp    x0, initial_user_payload
    add     x0, x0, :lo12:initial_user_payload
    ret

    .global initial_user_payload_len
initial_user_payload_len:
    adrp    x0, initial_user_payload
    add     x0, x0, :lo12:initial_user_payload
    adrp    x1, initial_user_payload_end
    add     x1, x1, :lo12:initial_user_payload_end
    sub     x0, x1, x0
    ret

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
    msr     sp_el0, x1
    /* EL0t with IRQ delivery enabled. The Lower-EL IRQ vector saves the
     * complete context before any scheduler decision. */
    mov     x2, #0
    msr     spsr_el1, x2
    msr     elr_el1, x0
    eret

    .global el0_sync_entry
    .type el0_sync_entry, %function
el0_sync_entry:
    sub     sp, sp, #EL0_CONTEXT_SIZE
    EL0_CONTEXT_SAVE

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
    b.eq    .Lsyscall_wait_uart
    cmp     x6, #7
    b.eq    .Lsyscall_exec
    cmp     x6, #8
    b.eq    .Lsyscall_child_exec
    mov     x16, #8
    b       el1_exception_evidence

.Ldata_abort:
    mrs     x1, far_el1
    bl      process_image_handle_data_abort
    cbz     x0, .Lsync_fail
    EL0_CONTEXT_RESTORE
    add     sp, sp, #EL0_CONTEXT_SIZE
    eret

.Lsync_fail:
    mov     x16, #8
    b       el1_exception_evidence

.Lsyscall_clone_child:
    // GitHub issue #221 Step 4: moved to kernel_syscall_clone_child_return
    // (.tkb), which replaces the hand-written EL0_CONTEXT_SIZE-word copy
    // loop with slice_copy and ends by sharing kernel_syscall_resume_return.
    mov     x0, sp
    mov     x1, x7
    b       kernel_syscall_clone_child_return

.Lclone_context_fail:
    mov     x16, #8
    b       el1_exception_evidence

.Lsyscall_clone_parent:
    /* x7 (the resumed parent's saved SP) is caller-saved, so it cannot be
     * held across the reap call -- once a child exec image is actually live,
     * that call reaches a deep unmap and clobbers it. Keep it in x19, which
     * is callee-saved here and is itself restored from the parent frame by
     * EL0_CONTEXT_RESTORE below, matching .Lsyscall_clone_child's pattern. */
    mov     x19, x7
    bl      kernel_process_child_exec_reap
    cbz     x19, .Lclone_context_fail
    mov     sp, x19
    EL0_CONTEXT_RESTORE
    add     sp, sp, #EL0_CONTEXT_SIZE
    eret

.Lsyscall_block:
    // GitHub issue #221 Step 2: moved to kernel_syscall_block_return (.tkb),
    // which ends in the single shared el0_context_resume/kernel_syscall_fail_stop
    // primitives above instead of hand-rolling the restore-and-eret sequence.
    mov     x0, sp
    b       kernel_syscall_block_return

.Lsyscall_wait_uart:
    /* interrupt_notify() emits SEV, so WFE retains an event that arrives
     * between the ppoll readiness check and entering the wait. */
    wfe
    b       .Lsyscall_dispatch

.Lsyscall_exec:
    /* Return to the EL1 image owner with the pending exec request. */
    mov     x0, x7
    add     sp, sp, #EL0_CONTEXT_SIZE
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldp     x27, x28, [sp, #64]
    ldp     x29, x30, [sp, #80]
    add     sp, sp, #96
    ret

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
    add     sp, sp, #EL0_CONTEXT_SIZE
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
    str     x1, [x0, #EL0_CONTEXT_X0]
    ret

    .global el0_context_set_elr_el1
el0_context_set_elr_el1:
    str     x1, [x0, #EL0_CONTEXT_ELR_EL1]
    ret

    .global el0_context_set_sp_el0
el0_context_set_sp_el0:
    str     x1, [x0, #EL0_CONTEXT_SP_EL0]
    ret

// GitHub issue #221 Step 2+: the single shared consumer for every action tail
// that resumes some already-fully-populated EL0 frame (the current frame with
// only a few fields changed, or an entirely different process's saved frame).
// Every `.Lsyscall_*` tail that used to hand-roll `EL0_CONTEXT_RESTORE; add sp,
// sp, #EL0_CONTEXT_SIZE; eret` itself now instead tail-branches into a small
// .tkb function that ends by calling this -- there is exactly one place left
// in the whole kernel that performs this restore-and-eret sequence, so two
// different code paths can no longer race to set elr_el1/sp_el0 and have one
// silently undone by the other's unconditional reload (see commit 8db27e3's
// first bug for the failure mode this replaces).
    .global el0_context_resume
el0_context_resume:
    mov     sp, x0
    EL0_CONTEXT_RESTORE
    add     sp, sp, #EL0_CONTEXT_SIZE
    eret

// The single shared fail-stop entry, replacing every hand-written
// `mov x16, #8; b el1_exception_evidence` pair at each .tkb-reachable action
// tail. x16=8 matches el0_sync_entry's own vector-slot identification
// (el1_vectors installs the lower-EL AArch64 sync slot at x16=8), so a
// fail-stop reached this way is indistinguishable in the recorded evidence
// from one reached directly out of el0_sync_entry.
    .global kernel_syscall_fail_stop
kernel_syscall_fail_stop:
    mov     x16, #8
    b       el1_exception_evidence
