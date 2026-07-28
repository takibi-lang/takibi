/* Embeds examples/common_aarch64/el0_shell_child_test.elf's own raw ELF
   bytes verbatim into el0_shell's kernel image (GitHub issue #158) --
   NOT cpio-wrapped, unlike examples/common_rpi3/el0_test_image.S's own
   copy of el0_test_prog.elf for examples/el0_elf_load: el0_shell.tkb's
   own execve() reads a real file's bytes directly off FAT12 (issue
   #157's own VFS bridge), the same shape a real openat()+read() sees,
   so app_main() just writes these bytes out to a FAT12 file at boot
   (see its own comment) rather than parsing a cpio archive to find
   them. */
    .section .rodata
    .align  4
    .global el0_shell_child_test_image_start
el0_shell_child_test_image_start:
    .incbin "examples/common_aarch64/el0_shell_child_test.elf"
    .global el0_shell_child_test_image_end
el0_shell_child_test_image_end:

    .section .text

/* usize el0_shell_child_test_image_addr(void) */
    .global el0_shell_child_test_image_addr
el0_shell_child_test_image_addr:
    adrp    x0, el0_shell_child_test_image_start
    add     x0, x0, :lo12:el0_shell_child_test_image_start
    ret

/* usize el0_shell_child_test_image_len(void) */
    .global el0_shell_child_test_image_len
el0_shell_child_test_image_len:
    adrp    x0, el0_shell_child_test_image_start
    add     x0, x0, :lo12:el0_shell_child_test_image_start
    adrp    x1, el0_shell_child_test_image_end
    add     x1, x1, :lo12:el0_shell_child_test_image_end
    sub     x0, x1, x0
    ret
