/* A real, standalone EL0 ELF binary (GitHub issue #158) -- the small,
   controlled first target execve() loads, matching this issue's own
   suggested staged approach ("prove the mechanism with a small,
   controlled real child ELF first", the same shape issue #153's own
   el0_test_prog.S already proved for the ORIGINAL loader). Deliberately
   does NOT read from stdin the way el0_test_prog.S does: a forked
   child's fd 0 is the SAME shared UART byte stream el0_shell.tkb's own
   parent shell process reads from (real Unix fork() semantics -- stdin
   is inherited, not duplicated), and this kernel has no per-process
   buffering to protect bytes the PARENT shell's own already-read-ahead
   buffering may have consumed before the child ever runs -- reusing
   el0_test_prog.elf's own read(0, buf, 3) here would make this test's
   correctness depend on exactly how much of el0_shell.stdin ash itself
   had already buffered internally before forking, not just something
   this kernel controls. Writes a fixed, checkable message and exits
   with a fixed, non-zero, non-1 status ($? checks would call 1 a
   different kind of "ok" for some shells; 42 could never be a Unix
   exit-status collision with an unrelated real failure) so a shell
   script can verify both fork()+execve()'s own output AND wait4()'s
   own real exit-status propagation in one command. */
    .section .text
    .global el0_prog_entry
el0_prog_entry:
    adr     x1, el0_prog_msg
    movz    x2, #14            /* EL0_PROG_MSG_LEN -- keep in sync */
    movz    x0, #1             /* fd = 1 (stdout) */
    movz    x8, #64            /* __NR_write */
    svc     #0
    movz    x1, #14
    cmp     x0, x1
    b.ne    .Lel0_prog_hang

    movz    x0, #42            /* exit status -- a deliberate, checkable
                                   value, not leftover from write()'s own
                                   x0 return */
    movz    x8, #93            /* __NR_exit */
    svc     #0
.Lel0_prog_hang:
    b       .Lel0_prog_hang

    .section .rodata
    .align  4
el0_prog_msg:
    .ascii  "child running\n"   /* EL0_PROG_MSG_LEN (14) bytes -- keep in sync */
