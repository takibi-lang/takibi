/* GitHub issue #228: links user_payload_tkb.o (compiled from
 * user_payload.tkb) with user_payload_asm.o (the two raw-asm
 * scheduler-preemption probe helpers) into a flat, position-independent
 * blob. The result is objcopied to raw binary and embedded into the kernel
 * image with embed_file -- see the Makefile's KERNEL_USER_PAYLOAD_BIN rule.
 *
 * `. = 0` plus `ENTRY(initial_user_payload)` matter only for humans/tools
 * reading this link step in isolation: objcopy -O binary drops the ELF
 * header (and with it e_entry) entirely, so the kernel's own loader always
 * starts execution at byte offset 0 of the blob. That is guaranteed by
 * listing user_payload_tkb.o (whose only externally-visible function,
 * initial_user_payload, is written first in user_payload.tkb) before
 * user_payload_asm.o on the link command line, so `*(.text*)` below places
 * it first in the output.
 *
 * The relaxation this depends on -- ld.lld converting the GOT-indirect
 * addressing Takibi/LLVM emits by default into direct PC-relative `adr`,
 * since this is a fully-resolved static link with no runtime relocation
 * processing -- was verified empirically before this file existed (see
 * HISTORY.md's #228 entry) rather than assumed.
 */
ENTRY(initial_user_payload)
SECTIONS {
    . = 0;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) }
    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) }
}
