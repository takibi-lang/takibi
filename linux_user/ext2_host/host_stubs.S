// GitHub issue #1035: the two assembly helpers of
// kernel/arch/arm64/kernel/cpu_stop_extern.tkb, for the host process.
//
// kernel_cpu_offset is TPIDR_EL1 on the board: this core's index times the
// per-core stride. The host process is one core, core 0, so it is 0.
//
// kernel_invariant_stop is the kernel's stop on a broken invariant. Here it
// writes a line the campaign driver recognises and exits with status 86,
// which no other path of the program uses.
    .text
    .global kernel_cpu_offset
kernel_cpu_offset:
    xor %eax, %eax
    ret

// preempt_count_add and preempt_count_reset reach the preempt word at the top
// of the board's stack run (#638). The host process is one task on a stack the
// kernel did not lay out, so its one count is a word of its own here.
// preempt_count_add(delta) returns the count before the add.
    .global preempt_count_add
preempt_count_add:
    mov .Lpreempt_count(%rip), %rax
    add %rax, %rdi
    mov %rdi, .Lpreempt_count(%rip)
    ret

    .global preempt_count_reset
preempt_count_reset:
    movq $0, .Lpreempt_count(%rip)
    ret

    .global kernel_invariant_stop
kernel_invariant_stop:
    mov $1, %rax
    mov $2, %rdi
    lea .Lstop_msg(%rip), %rsi
    mov $(.Lstop_end - .Lstop_msg), %rdx
    syscall
    mov $60, %rax
    mov $86, %rdi
    syscall
.Lstop_halt:
    hlt
    jmp .Lstop_halt

    .bss
    .balign 8
.Lpreempt_count:
    .skip 8

    .section .rodata
.Lstop_msg:
    .ascii "ext2-host: kernel_invariant_stop\n"
.Lstop_end:

    .section .note.GNU-stack,"",@progbits
