/* Linker script for el0_test_prog.S -- a real, standalone EL0 ELF binary
   (GitHub issue #153), not the kernel image itself. Loaded at exactly
   the same VA examples/el0_elf_load maps it to (0x80000000, the same
   dynamic mapping window examples/vm_page_map established) -- this is a
   non-PIE static binary, so its PT_LOAD's p_vaddr must match where the
   loader actually places it; nothing here performs relocation.

   ld.lld's own default output shape (a normal ELF file with real
   Elf64_Ehdr/Elf64_Phdr) is exactly what's wanted here, unlike the
   kernel's own link.ld's raw-section-layout style -- this file only
   needs to say where code/rodata start and which symbol is the entry
   point. */
ENTRY(el0_prog_entry)

SECTIONS {
    . = 0x80000000;

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
