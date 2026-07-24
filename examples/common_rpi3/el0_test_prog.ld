/* Linker script for el0_test_prog.S -- a real, standalone EL0 ELF binary
   (GitHub issue #153), not the kernel image itself. Linked as a
   static-pie (ET_DYN, base address 0), matching GitHub issue #156's own
   empirical finding that every real, unmodified shell binary worth
   targeting (Alpine's busybox-static and Debian/Raspbian's dash alike)
   is PIE -- both major distro toolchains switched their default to
   `-fPIE -pie` in the 2015-2018 hardening wave, static linking included.
   examples/el0_elf_load's loader picks a load bias at map time (see its
   own header comment); this hand-written test binary uses only
   PC-relative addressing (`adr`) internally, so it runs correctly at
   whatever bias the loader picks without needing any actual relocation
   processing itself (that's musl's own _start job for a real libc
   binary, out of this kernel's scope -- see el0_test_prog.S's own header
   comment for what this binary instead does: independently verify the
   loader's AT_PHDR/AT_PHNUM/AT_PHENT/AT_ENTRY auxv values are correct).

   ld.lld's own default output shape (a normal ELF file with real
   Elf64_Ehdr/Elf64_Phdr) is exactly what's wanted here, unlike the
   kernel's own link.ld's raw-section-layout style -- this file only
   needs to say where code/rodata start and which symbol is the entry
   point. */
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
