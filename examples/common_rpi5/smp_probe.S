/* Tiny, standalone MPIDR_EL1 probe for GitHub issue #163's real-hardware
   verification procedure -- see scripts/rpi5_check_core_topology.sh and
   examples/common_rpi5/AGENTS.md's own writeup. NOT linked into any
   kernel_rpi5.elf: this is deliberately its own minimal ELF, loaded at a
   scratch physical address (0x00090000, clear of jtag_stub.ld's 0x80000
   and link.ld's 0x200000) via OpenOCD's `load_image`, then reached by
   redirecting a HALTED core's own PC there and single-stepping through
   these two instructions -- never by actually resuming/handing off
   execution the normal way, and never by touching any of TF-A's own
   code or state. Reads x0 back afterward, then the calling script
   restores the core's original PC before resuming it, leaving it
   exactly as found. Safe to reuse for any future real-hardware register
   probe that only needs one or two `mrs`-only instructions and no
   memory access, following the same read-only, restore-before-resume
   discipline documented in AGENTS.md's own probe history (the HCR_EL2
   probe from issue #165 is the same idea, just as a normal loaded
   kernel rather than this single-step variant). */
.section .text.boot
.global _start
_start:
    mrs x0, mpidr_el1
.Lspin:
    wfe
    b .Lspin
