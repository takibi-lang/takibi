/* A real, standalone, statically-linked EL0 ELF binary (GitHub issue #153:
   the first target for a genuine ELF loader, as opposed to el0_smoke's
   raw hand-copied instruction bytes). Built into its own ELF file (see
   el0_test_prog.ld) by this repo's own toolchain (llvm-mc + ld.lld), then
   embedded into the kernel image verbatim via el0_test_image.S's
   `.incbin` -- the kernel-side loader (examples/el0_elf_load) parses this
   file's real Elf64_Ehdr/Elf64_Phdr, not a hardcoded offset/length.

   Same syscall sequence as el0_smoke's own payload: write(1, msg, 12)
   then exit(93), still no memory access beyond its own embedded message
   (adr is PC-relative, so it works whether this segment lands at its
   link-time address or not -- though el0_test_prog.ld pins one anyway,
   see that file's own comment for why). */
    .section .text
    .global el0_prog_entry
el0_prog_entry:
    adr     x1, el0_prog_msg
    movz    x2, #12            /* EL0_PROG_MSG_LEN -- must match el0_prog_msg */
    movz    x0, #1             /* fd = 1 (stdout) */
    movz    x8, #64            /* __NR_write */
    svc     #0
    movz    x1, #12
    cmp     x0, x1
    b.ne    .Lel0_prog_hang
    movz    x0, #0              /* exit status 0 (success) -- a deliberate
                                    value, not leftover from write()'s own
                                    x0 return, so the kernel-reported exit
                                    status is a real signal, not noise */
    movz    x8, #93            /* __NR_exit */
    svc     #0
.Lel0_prog_hang:
    b       .Lel0_prog_hang

    .section .rodata
    .align  4
el0_prog_msg:
    .ascii  "hi from ELF\n"    /* EL0_PROG_MSG_LEN (12) bytes -- keep in sync */
