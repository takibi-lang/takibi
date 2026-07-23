/* Embeds the real, standalone EL0 ELF file (el0_test_prog.S/.ld, built by
   this repo's own toolchain) into the kernel image verbatim, so
   examples/el0_elf_load's Takibi code can parse it as genuine ELF bytes
   -- not a hardcoded offset/length like el0_smoke's raw payload copy.
   `.incbin` requires el0_test_prog.elf to already exist at assemble time
   (see the Makefile's ordering: el0_test_prog.elf is a prerequisite of
   this file's own .o rule). */
    .section .rodata
    .align  4
    .global el0_test_image_start
el0_test_image_start:
    .incbin "examples/common_rpi3/el0_test_prog.elf"
    .global el0_test_image_end
el0_test_image_end:

    .section .text

/* usize el0_test_image_addr(void) */
    .global el0_test_image_addr
el0_test_image_addr:
    adrp    x0, el0_test_image_start
    add     x0, x0, :lo12:el0_test_image_start
    ret

/* usize el0_test_image_len(void) */
    .global el0_test_image_len
el0_test_image_len:
    adrp    x0, el0_test_image_start
    add     x0, x0, :lo12:el0_test_image_start
    adrp    x1, el0_test_image_end
    add     x1, x1, :lo12:el0_test_image_end
    sub     x0, x1, x0
    ret
