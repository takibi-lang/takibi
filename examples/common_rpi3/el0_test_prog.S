/* A real, standalone EL0 ELF binary (GitHub issue #153: the first target
   for a genuine ELF loader, as opposed to el0_smoke's raw hand-copied
   instruction bytes). Built into its own ELF file (see el0_test_prog.ld)
   by this repo's own toolchain (llvm-mc + ld.lld), then embedded into the
   kernel image verbatim via el0_test_image.S's `.incbin` -- the
   kernel-side loader (examples/el0_elf_load) parses this file's real
   Elf64_Ehdr/Elf64_Phdr, not a hardcoded offset/length.

   Linked as a static-pie (ET_DYN, base 0 -- see el0_test_prog.ld's own
   comment on why every real target binary is PIE, GitHub issue #156).
   First validates the argv/envp/auxv initial stack layout INCLUDING the
   PIE-specific entries (AT_PHDR/AT_PHENT/AT_PHNUM/AT_BASE/AT_ENTRY/
   AT_RANDOM/AT_SECURE) the loader's load-bias mechanism must get right
   for a real libc's own self-relocation and TLS setup to work -- every
   real libc's own startup code reads this off SP unconditionally, so
   getting it right is a prerequisite more fundamental than any
   individual syscall. Then the same write(1, msg, 12) opener as
   el0_smoke's own payload, a real read(0, buf, 3) (GitHub issue #153's
   third and last Stage 1 syscall) that echoes back whatever three bytes
   arrive over UART RX via a second write(), before exit(0). No memory
   access beyond the argv/auxv layout and its own embedded message/buffer,
   EXCEPT for a real push/pop through SP -- proving
   examples/el0_elf_load's real mapped stack page actually works, not
   just that SP_EL0 holds a valid-looking value nothing ever
   dereferences. (adr is PC-relative, so both the message/buffer and the
   entry point itself work whether this segment lands at its link-time
   address or not -- which for a PIE binary it never does; the loader
   always chooses a real, non-zero load bias, so THIS running at all,
   let alone validating AT_ENTRY, is itself already partial proof the
   mechanism works. SP is a real mapped VA, not position-independent, but
   the loader always maps the stack page at a fixed, known offset from
   the code region, so this is safe.) */
    .section .text
    .global el0_prog_entry
el0_prog_entry:
    /* argv/envp/auxv validation -- MUST run before SP is touched at all
       (the marker push below), since the initial SP IS the argc pointer;
       moving it first would lose the only reference to this layout.
       Expected layout (examples/el0_elf_load's app_main constructs this
       exactly): argc=1, argv[0]="prog\0", argv NULL, envp NULL (zero
       entries), auxv (AT_PAGESZ, AT_PHDR, AT_PHENT, AT_PHNUM, AT_BASE,
       AT_ENTRY, AT_RANDOM, AT_SECURE), (AT_NULL, 0). x19 holds this
       binary's own runtime load bias for the rest of this function --
       el0_prog_entry links at vaddr 0 (el0_test_prog.ld's `. = 0;`), so
       `adr` (PC-relative, always correct regardless of where the loader
       actually placed this binary) gives exactly the bias itself. */
    adr     x19, el0_prog_entry
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

    /* auxv[1]: AT_PHDR (3) -- must equal this binary's own load bias
       plus its link-time e_phoff (64, verified via `readelf -h` against
       this exact linker script/source -- same empirical-constant idiom
       as examples/el0_elf_load.tkb's own CPIO_FILESIZE_OFFSET). */
    ldr     x9, [sp, #48]
    movz    x10, #3
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #56]
    movz    x10, #64                  /* this binary's own e_phoff */
    add     x10, x19, x10
    cmp     x9, x10
    b.ne    .Lel0_prog_hang

    /* auxv[2]: AT_PHENT (4) = 56 (sizeof(Elf64_Phdr), architecture-fixed) */
    ldr     x9, [sp, #64]
    movz    x10, #4
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #72]
    movz    x10, #56
    cmp     x9, x10
    b.ne    .Lel0_prog_hang

    /* auxv[3]: AT_PHNUM (5) = 6 (this exact linked binary's own program
       header count, verified via `readelf -h`) */
    ldr     x9, [sp, #80]
    movz    x10, #5
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #88]
    movz    x10, #6
    cmp     x9, x10
    b.ne    .Lel0_prog_hang

    /* auxv[4]: AT_BASE (7) = 0 (no separate interpreter is ever loaded) */
    ldr     x9, [sp, #96]
    movz    x10, #7
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #104]
    cbnz    x9, .Lel0_prog_hang

    /* auxv[5]: AT_ENTRY (9) -- must equal this binary's own real runtime
       entry address, i.e. exactly the load bias (el0_prog_entry links at
       vaddr 0, so bias + e_entry(0) == bias). */
    ldr     x9, [sp, #112]
    movz    x10, #9
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #120]
    cmp     x9, x19
    b.ne    .Lel0_prog_hang

    /* auxv[6]: AT_RANDOM (25) -- just a non-NULL pointer; the pointee's
       content is a deliberate low-quality fixed stub (GitHub issue
       #156's own hedge on real entropy quality being a later concern),
       not checked here. */
    ldr     x9, [sp, #128]
    movz    x10, #25
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #136]
    cbz     x9, .Lel0_prog_hang

    /* auxv[7]: AT_SECURE (23) = 0 (no privilege transition ever happens) */
    ldr     x9, [sp, #144]
    movz    x10, #23
    cmp     x9, x10
    b.ne    .Lel0_prog_hang
    ldr     x9, [sp, #152]
    cbnz    x9, .Lel0_prog_hang

    ldr     x9, [sp, #160]             /* auxv terminator: AT_NULL (0) */
    cbnz    x9, .Lel0_prog_hang
    ldr     x9, [sp, #168]             /* auxv terminator's value, also 0 */
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

    /* Loop reading until EL0_PROG_STDIN_LEN (3) bytes are accumulated --
       a real short read is now expected (GitHub issue #156: this
       kernel's read() returns as soon as ANY data is ready, not only
       once the full request is filled, matching real POSIX semantics
       instead of the earlier "always fills exactly len" simplification)
       -- so a defensively-written client must retry rather than assume
       one call fills the buffer, exactly like any real program reading
       a fixed-size record over a byte stream. x21 (bytes accumulated
       so far) and x22 (call count guard, so a 0-byte "success" can
       never spin forever) are both callee-saved, surviving the SVC
       round trip. */
    movz    x21, #0
    movz    x22, #0
.Lel0_prog_read_loop:
    adr     x1, el0_prog_stdin_buf
    add     x1, x1, x21
    movz    x2, #3
    sub     x2, x2, x21
    movz    x0, #0             /* fd = 0 (stdin) */
    movz    x8, #63            /* __NR_read */
    svc     #0
    cmp     x0, #0
    b.le    .Lel0_prog_hang    /* error, or a 0-byte read: give up */
    add     x21, x21, x0
    add     x22, x22, #1
    movz    x9, #64            /* generous retry cap -- 3 bytes should
                                   never legitimately take this many
                                   short reads; a real bug should hang
                                   visibly here, not loop forever */
    cmp     x22, x9
    b.ge    .Lel0_prog_hang
    cmp     x21, #3
    b.lt    .Lel0_prog_read_loop

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
