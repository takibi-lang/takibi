/* A real, standalone, statically-linked EL0 ELF binary (GitHub issue #153:
   the first target for a genuine ELF loader, as opposed to el0_smoke's
   raw hand-copied instruction bytes). Built into its own ELF file (see
   el0_test_prog.ld) by this repo's own toolchain (llvm-mc + ld.lld), then
   embedded into the kernel image verbatim via el0_test_image.S's
   `.incbin` -- the kernel-side loader (examples/el0_elf_load) parses this
   file's real Elf64_Ehdr/Elf64_Phdr, not a hardcoded offset/length.

   First validates the argv/envp/auxv initial stack layout (GitHub issue
   #156's first concrete milestone -- every real libc's own startup code
   reads this off SP unconditionally, so getting it right is a
   prerequisite more fundamental than any individual syscall). Then the
   same write(1, msg, 12) opener as el0_smoke's own payload, a real
   read(0, buf, 3) (GitHub issue #153's third and last Stage 1 syscall)
   that echoes back whatever three bytes arrive over UART RX via a second
   write(), before exit(0). No memory access beyond the argv/auxv layout
   and its own embedded message/buffer, EXCEPT for a real push/pop
   through SP -- proving examples/el0_elf_load's real mapped stack page
   actually works, not just that SP_EL0 holds a valid-looking value
   nothing ever dereferences. (adr is PC-relative, so both the
   message/buffer and the entry point itself work whether this segment
   lands at its link-time address or not -- though el0_test_prog.ld pins
   one anyway, see that file's own comment for why. SP is a real mapped
   VA, not position-independent, but the loader always maps the stack
   page at a fixed, known offset from the code page, so this is safe.) */
    .section .text
    .global el0_prog_entry
el0_prog_entry:
    /* argv/envp/auxv validation -- MUST run before SP is touched at all
       (the marker push below), since the initial SP IS the argc pointer;
       moving it first would lose the only reference to this layout.
       Expected layout (examples/el0_elf_load's app_main constructs this
       exactly): argc=1, argv[0]="prog\0", argv NULL, envp NULL (zero
       entries), auxv (AT_PAGESZ, 4096), (AT_NULL, 0). */
    ldr     x9, [sp]                   /* argc */
    movz    x10, #1
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #8]               /* argv[0] pointer */
    ldr     w10, [x9]                  /* first 4 bytes: "prog" little-endian */
    movz    w11, #0x7270
    movk    w11, #0x676f, lsl #16
    cmp     w10, w11
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #16]              /* argv NULL terminator */
    cbnz    x9, .Lel0_prog_hang
    ldr     x9, [sp, #24]              /* envp NULL terminator (0 entries) */
    cbnz    x9, .Lel0_prog_hang
    ldr     x9, [sp, #32]              /* auxv[0].a_type, expect AT_PAGESZ (6) */
    movz    x10, #6
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #40]              /* auxv[0].a_val, expect 4096 */
    movz    x10, #4096
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #48]              /* auxv terminator: AT_NULL (0) */
    cbnz    x9, .Lel0_prog_hang
    ldr     x9, [sp, #56]              /* auxv terminator's value, also 0 */
    cbnz    x9, .Lel0_prog_hang

    adr     x1, el0_prog_argv_ok_msg
    movz    x2, #13            /* EL0_PROG_ARGV_OK_MSG_LEN */
    movz    x0, #1
    movz    x8, #64
    svc     #0
    movz    x1, #13
    cmp     x0, x1
    b.ne    .Lel0_prog_hang

    movz    x0, #0x1234        /* marker pushed onto the real stack, popped
                                   and checked again after several SVC
                                   round trips -- proves the mapped stack
                                   page survives intervening kernel entry/
                                   exit and that SP genuinely points at
                                   real, private, readable/writable memory */
    movz    x1, #0x5678
    stp     x0, x1, [sp, #-16]!

    adr     x1, el0_prog_msg
    movz    x2, #12            /* EL0_PROG_MSG_LEN -- must match el0_prog_msg */
    movz    x0, #1             /* fd = 1 (stdout) */
    movz    x8, #64            /* __NR_write */
    svc     #0
    movz    x1, #12
    cmp     x0, x1
    b.ne    .Lel0_prog_hang

    adr     x1, el0_prog_stdin_buf
    movz    x2, #3             /* EL0_PROG_STDIN_LEN -- must match the buffer */
    movz    x0, #0             /* fd = 0 (stdin) */
    movz    x8, #63            /* __NR_read */
    svc     #0
    movz    x1, #3
    cmp     x0, x1
    b.ne    .Lel0_prog_hang

    adr     x1, el0_prog_stdin_buf
    movz    x2, #3
    movz    x0, #1             /* fd = 1 (stdout) -- echo back what was read */
    movz    x8, #64            /* __NR_write */
    svc     #0
    movz    x1, #3
    cmp     x0, x1
    b.ne    .Lel0_prog_hang

    ldp     x0, x1, [sp], #16  /* pop the marker pushed at entry -- if SP
                                   were not really backed by private,
                                   correctly-mapped memory, or if any SVC
                                   round trip above had corrupted it, this
                                   would not read back the exact values
                                   just pushed */
    movz    x2, #0x1234
    cmp     x0, x2
    b.ne    .Lel0_prog_hang
    movz    x2, #0x5678
    cmp     x1, x2
    b.ne    .Lel0_prog_hang

    movz    x0, #0              /* exit status 0 (success) -- a deliberate
                                    value, not leftover from write()'s own
                                    x0 return, so the kernel-reported exit
                                    status is a real signal, not noise */
    movz    x8, #93            /* __NR_exit */
    svc     #0
.Lel0_prog_hang:
    b       .Lel0_prog_hang

    /* Dead padding (never executed) pushing this binary's .text PT_LOAD
       segment past one PAGE_SIZE (4096 bytes) -- GitHub issue #156's
       multi-page loader proof needs a real ELF that genuinely spans more
       than one page, not just the primitive-level proof
       examples/process_vm_smoke already gave the underlying
       ProcessAddressSpace mechanism. 6000 bytes puts total .text size at
       ~6288 bytes, comfortably past the 4096 boundary while still fitting
       in 2 code pages (MAX_PROCESS_PAGES=4 in vm_page_map_core.tkb, one
       page reserved for the stack). */
    .space  6000

    .section .rodata
    .align  4
el0_prog_argv_ok_msg:
    .ascii  "argv/auxv ok\n"   /* EL0_PROG_ARGV_OK_MSG_LEN (13) bytes -- keep in sync */
el0_prog_msg:
    .ascii  "hi from ELF\n"    /* EL0_PROG_MSG_LEN (12) bytes -- keep in sync */
el0_prog_stdin_buf:
    .space  3                  /* EL0_PROG_STDIN_LEN bytes, zero-initialized
                                   on disk (included in this PT_LOAD segment's
                                   filesz, so the loader's plain byte copy
                                   needs no separate bss/memsz-zero-fill
                                   support for this to work) */
