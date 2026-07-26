/* Linker script for el0_test_prog.S -- a real, standalone EL0 ELF binary
   for RPi5 (GitHub issue #67 Stage 2 follow-up), not the kernel image
   itself. Identical in structure to examples/common_rpi3/
   el0_test_prog.ld -- this script is entirely target-independent (no
   RPi3/RPi5-specific addresses or sections), kept as its own small copy
   only to match this repo's own COMMON_RPI5_*-scoped Makefile variable
   convention, not because its content needs to differ.

   Linked as a static-pie (ET_DYN, base address 0). ld.lld's own default
   output shape (a normal ELF file with real Elf64_Ehdr/Elf64_Phdr) is
   exactly what's wanted here, unlike the kernel's own link.ld's
   raw-section-layout style -- this file only needs to say where
   code/rodata start and which symbol is the entry point. */
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
