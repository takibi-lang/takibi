/* Embeds a real cpio (newc) initramfs image into the kernel image
   verbatim, so examples/el0_elf_load's Takibi code can parse it as
   genuine cpio + ELF bytes -- not a hardcoded offset/length like
   el0_smoke's raw payload copy. The archive is built by the real `cpio`
   tool (see the Makefile's own rule) from el0_test_prog.S/.ld's output
   (the real, standalone EL0 ELF file), not hand-assembled. `.incbin`
   requires initramfs.cpio to already exist at assemble time (see the
   Makefile's ordering: initramfs.cpio is a prerequisite of this file's
   own .o rule). */
    .section .rodata
    .align  4
    .global el0_test_image_start
el0_test_image_start:
    .incbin "examples/common_rpi3/initramfs.cpio"
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
