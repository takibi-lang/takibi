/* Embeds a real cpio (newc) initramfs image into the kernel image
   verbatim, so examples/el0_shell's Takibi code can parse it as genuine
   cpio + ELF bytes -- the same mechanism examples/el0_elf_load's own
   el0_test_image.S already established, just pointed at a real,
   unmodified, third-party shell binary (Alpine Linux's busybox-static,
   aarch64) instead of this repo's own hand-written test program
   (GitHub issue #156). The archive is built by the real `cpio` tool
   (see the Makefile's own rule) from a binary downloaded fresh at build
   time, not vendored into this repository -- see the Makefile's own
   COMMON_RPI3_BUSYBOX_APK rule for why. `.incbin` requires
   el0_shell_initramfs.cpio to already exist at assemble time (see the
   Makefile's ordering). */
    .section .rodata
    .align  4
    .global el0_shell_image_start
el0_shell_image_start:
    .incbin "examples/common_rpi3/el0_shell_initramfs.cpio"
    .global el0_shell_image_end
el0_shell_image_end:

    .section .text

/* usize el0_shell_image_addr(void) */
    .global el0_shell_image_addr
el0_shell_image_addr:
    adrp    x0, el0_shell_image_start
    add     x0, x0, :lo12:el0_shell_image_start
    ret

/* usize el0_shell_image_len(void) */
    .global el0_shell_image_len
el0_shell_image_len:
    adrp    x0, el0_shell_image_start
    add     x0, x0, :lo12:el0_shell_image_start
    adrp    x1, el0_shell_image_end
    add     x1, x1, :lo12:el0_shell_image_end
    sub     x0, x1, x0
    ret
