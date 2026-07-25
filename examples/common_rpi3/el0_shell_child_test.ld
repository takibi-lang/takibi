/* Linker script for el0_shell_child_test.S (GitHub issue #158) -- same
   shape as examples/common_rpi3/el0_test_prog.ld (see that file's own
   header comment for the full reasoning: static-pie, base address 0,
   PC-relative addressing only so no relocation processing is needed).
   Kept as its own copy rather than a shared script: the two source
   files are deliberately independent standalone ELF targets (see
   el0_shell_child_test.S's own header comment for why this one exists
   at all instead of reusing el0_test_prog.elf), and sharing a linker
   script across them would imply a coupling that does not actually
   exist. */
ENTRY(el0_prog_entry)

SECTIONS {
    . = 0;

    .text : {
        *(.text .text.*)
    }

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
    }
}
