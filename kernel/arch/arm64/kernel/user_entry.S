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
    mov     x0, #42
    mov     x8, #93
    svc     #0
.Lclone_parent_done:

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
.Luser_message:
    .ascii  "hello from userspace\n"
.Lmutable_path:
    .asciz  "/mutable.txt"
.Lmutable_content:
    .ascii  "el0-ok\n"
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

    .section .bss, "aw", %nobits
    .align 12
clone_child_kernel_stack:
    .skip   4096
clone_child_kernel_stack_end:
    .align 3
clone_parent_frame:
    .skip   8

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
    mov     x2, #0x3c0
    msr     spsr_el1, x2
    msr     elr_el1, x0
    eret

    .global el0_sync_entry
    .type el0_sync_entry, %function
el0_sync_entry:
    sub     sp, sp, #EL0_CONTEXT_SIZE
    EL0_CONTEXT_SAVE

    /* GitHub issue #187: exception entry unconditionally masks DAIF, so
     * without this, any syscall whose handling reaches a real
     * interrupt_wait() (RP1 USB xHCI's disk I/O completion) blocks
     * forever -- its own xhci_irq_handler ISR can never be taken while I
     * is masked, so the paired wfe/sev never wakes. Safe to clear here:
     * a nested IRQ lands on this same SP_EL1 stack, strictly below this
     * frame, and el1_current_irq_entry's own save/restore does not touch
     * any state already saved above. .Lsyscall_resume's eret restores the
     * ORIGINAL captured SPSR_EL1 (DAIF already masked for EL0t), and the
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
    mov     x16, #8
    b       el1_exception_evidence

.Lsyscall_clone_child:
    /* Preserve the parent's complete syscall frame, then give the child a
     * distinct EL1 kernel stack containing its own copy of that frame. */
    adrp    x9, clone_parent_frame
    add     x9, x9, :lo12:clone_parent_frame
    mov     x14, sp
    str     x14, [x9]
    adrp    x10, clone_child_kernel_stack_end
    add     x10, x10, :lo12:clone_child_kernel_stack_end
    sub     x10, x10, #EL0_CONTEXT_SIZE
    mov     x11, sp
    mov     x12, #EL0_CONTEXT_SIZE
.Lclone_frame_copy:
    ldr     x13, [x11], #8
    str     x13, [x10], #8
    subs    x12, x12, #8
    b.ne    .Lclone_frame_copy
    adrp    x10, clone_child_kernel_stack_end
    add     x10, x10, :lo12:clone_child_kernel_stack_end
    sub     sp, x10, #EL0_CONTEXT_SIZE
    mov     x7, #0
    b       .Lsyscall_resume

.Lsyscall_clone_parent:
    adrp    x9, clone_parent_frame
    add     x9, x9, :lo12:clone_parent_frame
    ldr     x14, [x9]
    mov     sp, x14
    b       .Lsyscall_resume

.Lsyscall_resume:
    str     x7, [sp, #EL0_CONTEXT_X0]
    EL0_CONTEXT_RESTORE
    add     sp, sp, #EL0_CONTEXT_SIZE
    eret

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
