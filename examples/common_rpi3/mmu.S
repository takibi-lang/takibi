/* Minimal AArch64 EL2 identity-map MMU setup for BCM2837 (Raspberry Pi
   3B) bare-metal code -- see examples/common_rpi3/AGENTS.md's "MMU"
   entry for the full rationale: without this, code compiled by LLVM for
   this target can be silently miscompiled into unaligned wide
   loads/stores by ordinary store-merging optimization (confirmed via
   examples/packed and examples/inet_checksum both faulting with
   ESR_EL2 0x96000061 -- EC 0x25 "Data Abort, same EL", DFSC "Alignment
   fault" -- on a WIDE STORE THE COMPILER SYNTHESIZED from several
   adjacent 1-byte source-level writes, not from anything the .tkb source
   itself did unaligned). This is a general LLVM-backend phenomenon (any
   language using LLVM -- C/Clang, Rust, Zig -- is equally exposed), not
   specific to takibi, and the reason essentially every real-world
   bare-metal AArch64 project enables the MMU during early boot: with the
   stage 1 MMU disabled, AArch64 architecturally treats ALL data accesses
   as Device-nGnRnE memory, which enforces natural alignment
   unconditionally, regardless of SCTLR_ELx.A.

   Two-level identity map (VA == PA), 4KB translation granule, T0SZ=25
   (39-bit input address -> L1 covers 1GB/entry, L2 covers 2MB/entry,
   matching this SoC's memory map exactly). L1 entry 0 (physical
   0x00000000-0x3FFFFFFF) covers RAM and BCM2837's main peripheral block
   (0x3F000000-0x3FFFFFFF, see examples/common_rpi3/uart.tkb's register
   addresses) in one L2 table: L2 entries 0-503 (0x00000000-0x3EFFFFFF)
   are Normal Write-Back Cacheable (RAM); L2 entries 504-511
   (0x3F000000-0x3FFFFFFF) are Device-nGnRnE (peripherals) -- 0x3F000000
   / 0x200000 = 504 exactly, so this split falls cleanly on a 2MB block
   boundary.

   L1 entry 1 (physical 0x40000000-0x7FFFFFFF) covers the SEPARATE "ARM
   Local"/QA7 peripheral block examples/common_rpi3/intc.tkb's GPU IRQ
   routing/Core0 IRQ source registers live in (0x40000000-0x400000FF) --
   a genuinely different physical range from the 0x3F000000 block above,
   easy to miss (confirmed the hard way: examples/echo/examples/irq both
   faulted with a Level 1 TRANSLATION fault, DFSC 0b000101, writing
   0x4000000C -- an address this map simply had no entry for at all,
   distinct from the earlier unaligned-ACCESS fault class this file's
   own existence otherwise fixes). Only L2 entry 0 of this second table
   is populated (Device-nGnRnE, covering 0x40000000-0x401FFFFF, more
   than enough for the ~0x100-byte QA7 register block); entries 1-511
   are left at their BSS-cleared all-zero (invalid) state -- nothing
   else in that 1GB range is used.

   Called from examples/common_rpi3/startup.S's _start, AFTER BSS has
   already been cleared (l1_table/l2_table below live in .bss, so they
   must be zeroed by that ordinary BSS-clear loop -- with MMU still off
   at that point, a plain 8-byte-aligned str loop needs no special
   handling -- BEFORE mmu_init runs, not after: reversing that order
   would zero out the live page tables this code just built, out from
   under the MMU it just enabled). */
    .section .bss
    .align  12              /* 4KB alignment, required for a translation
                                table base address */
l1_table:
    .space  4096
l2_table:
    .space  4096
l2_table_local:
    .space  4096

    .section .text
    .global mmu_init
mmu_init:
    /* L1 entry 0: table descriptor pointing at l2_table. Table
       descriptor format: bits[1:0] = 0b11, bits[47:12] = next-level
       table's base address (already 4KB-aligned above). */
    adrp    x0, l2_table
    add     x0, x0, :lo12:l2_table
    orr     x0, x0, #0x3
    adrp    x1, l1_table
    add     x1, x1, :lo12:l1_table
    str     x0, [x1]

    /* L1 entry 1: table descriptor pointing at l2_table_local (the ARM
       Local/QA7 block, see this file's header comment). */
    adrp    x0, l2_table_local
    add     x0, x0, :lo12:l2_table_local
    orr     x0, x0, #0x3
    str     x0, [x1, #8]

    /* l2_table_local entry 0: a single Device-nGnRnE 2MB block covering
       physical 0x40000000-0x401FFFFF. The descriptor's output-address
       field holds the ABSOLUTE physical block base (0x40000000), not an
       offset relative to what this table happens to cover -- an earlier
       version of this line wrote just the attribute word 0x401 (output
       address 0), which silently identity-UNmapped the whole QA7 block
       onto physical 0x000000xx RAM instead: every intc.tkb register
       read/write landed in the GPU firmware's armstub8 code at physical
       0 (confirmed by reading VA 0x40000060 back and getting
       0xd51e4020, an `msr elr_el3, x0` instruction -- EL3 stub code, in
       an image that contains no EL3 instructions of its own), so
       intc_uart_irq_pending() never saw the GPU IRQ bit and every UART
       interrupt looped forever undispatched. The GPU->core0 routing
       write was equally fake, and only worked because QA7's reset
       default already routes to core 0. Attributes: AttrIndx 0 (Device)
       | AF (bit 10) | SH=00 Non-shareable | valid+block (bits 1:0)
       = 0x401, matching l2_table's own Device entries below. */
    adrp    x1, l2_table_local
    add     x1, x1, :lo12:l2_table_local
    movz    x4, #0x401
    movk    x4, #0x4000, lsl #16
    str     x4, [x1]

    /* L2 table: 512 entries, each a 2MB block descriptor. Block
       descriptor format: bits[1:0] = 0b01 (valid, block -- not table,
       since this is the last level we walk), bits[47:21] = output
       address (2MB-aligned; identity-mapped, so this equals the entry
       index shifted left 21), plus attributes:
         entries 0-503 (RAM, index < x6):   0x705 = AttrIndx 1 (Normal,
           MAIR_EL2 byte 1) | AF (bit 10) | SH=11 Inner Shareable
           (bits 9:8) | valid+block (bits 1:0)
         entries 504-511 (peripherals):     0x401 = AttrIndx 0 (Device,
           MAIR_EL2 byte 0) | AF (bit 10) | SH=00 Non-shareable |
           valid+block
       Both attribute words fit a single 16-bit MOVZ immediate, so no
       ORR-immediate bitmask-encodability concerns here. */
    adrp    x1, l2_table
    add     x1, x1, :lo12:l2_table
    mov     x2, #0                  /* entry index, also >> 21 of the
                                        output address since this is an
                                        identity map */
    mov     x6, #504                /* first peripheral (Device) entry */
    mov     x7, #512                /* one past the last entry */
.Ll2_loop:
    cmp     x2, x7
    b.ge    .Ll2_done
    cmp     x2, x6
    b.lt    .Ll2_normal
    mov     x5, #0x401               /* Device */
    b       .Ll2_store
.Ll2_normal:
    mov     x5, #0x705               /* Normal WB Cacheable */
.Ll2_store:
    orr     x4, x5, x2, lsl #21      /* combine attrs with 2MB-aligned
                                         output address */
    str     x4, [x1, x2, lsl #3]
    add     x2, x2, #1
    b       .Ll2_loop
.Ll2_done:

    /* MAIR_EL2: byte 0 (AttrIndx 0) = 0x00 Device-nGnRnE; byte 1
       (AttrIndx 1) = 0xFF Normal, Inner/Outer Write-Back
       Read/Write-Allocate Cacheable. */
    movz    x0, #0xff00
    msr     mair_el2, x0

    /* TCR_EL2 = 0x80803519: T0SZ=25 (bits 5:0), IRGN0=01 Write-Back RA/WA
       (bits 9:8), ORGN0=01 (bits 11:10), SH0=11 Inner Shareable
       (bits 13:12), TG0=00 4KB granule (bits 15:14), PS=000 32-bit
       (bits 18:16; this board has well under 4GB of address space),
       plus the two architecturally-RES1 bits confirmed against ARM's
       TCR_EL2 register reference: bit 23 and bit 31. Built via
       movz+movk rather than a single immediate/ORR sequence since bits
       23 and 31 are not contiguous (not a valid AArch64 ORR-immediate
       bitmask on their own combined with the rest). */
    movz    x0, #0x3519
    movk    x0, #0x8080, lsl #16
    msr     tcr_el2, x0

    adrp    x0, l1_table
    add     x0, x0, :lo12:l1_table
    msr     ttbr0_el2, x0

    isb
    dsb     sy

    /* Invalidate any stale TLB entries from a previous occupant of this
       core before enabling translation -- see startup.S's comment on
       why system-register/TLB state here is inherited, not reset, when
       a payload is injected via JTAG rather than reaching this code via
       a genuine hardware reset. */
    tlbi    alle2
    dsb     sy
    isb

    /* Enable the MMU (SCTLR_EL2.M) only -- deliberately leave the D-cache
       (C) and I-cache (I) disabled. This is not a performance-neutral
       choice; it is required for correctness under this project's
       specific JTAG re-injection workflow (scripts/rpi3_jtag_load.sh):
       OpenOCD's `load_image` writes a new payload directly into
       physical RAM over the debug port, bypassing the CPU's caches
       entirely (like a DMA write) -- confirmed the hard way, with
       caching on: the FIRST injection after enabling the MMU ran
       correctly (nothing cached yet to go stale), but the SECOND
       (loading examples/packed on top of the address range
       examples/hello had just finished running from) produced garbled
       UART output, with UART0's own registers reading back exactly the
       values uart_init() should have produced -- i.e. the peripheral
       side was fine, and the CPU was executing/reading stale cached
       instructions/data left over from the PREVIOUS occupant of these
       same physical addresses. OpenOCD's aarch64 target here does not
       expose SCTLR_EL2 as a directly settable register (confirmed:
       "register sctlr_el2 not found in current target"), so there is
       no way to force a clean cache-disabled state from the JTAG side
       before each injection either. With the D/I-cache left off,
       `load_image`'s direct-to-RAM writes and this core's own
       subsequent fetches/loads are trivially coherent (no cache in the
       path to go stale), matching how a genuine cold boot's first-ever
       execution is always coherent by construction. The MMU alone
       (page-table memory attributes, not cache-enable bits) is what
       actually fixes the unaligned-access fault this file exists for --
       see this file's own header comment.

       SCTLR_EL2 is itself inherited state, same as everything else this
       file's header discusses (see startup.S's own comment on why) --
       explicitly CLEAR the C/I bits with BIC, not just refrain from
       setting them with ORR: a PREVIOUS payload that had caching
       enabled (e.g. an earlier build of this very file, before this
       fix) leaves SCTLR_EL2.C/I set for whatever runs next, and `orr
       x0, x0, #1` alone only adds the M bit on top of that inherited
       state rather than overriding it -- confirmed the hard way: a
       batch of `make hwcheck-rpi3` runs where only the very first
       example passed and every other one produced garbage, because the
       first example's own catch inherited stale cache-enabled state
       from an unrelated prior manual test, and every following example
       then inherited caching-enabled state from the ONE before it in
       the same run (this file's old ORR-only write never cleared it
       once set). BIC needs two separate immediates: bit 2 and bit 12
       are not a contiguous run, so `#(1<<2)|(1<<12)` is not a valid
       single AArch64 bitmask immediate. */
    mrs     x0, sctlr_el2
    bic     x0, x0, #(1 << 2)        /* SCTLR_EL2.C: force D-cache off */
    bic     x0, x0, #(1 << 12)       /* SCTLR_EL2.I: force I-cache off */
    orr     x0, x0, #1               /* SCTLR_EL2.M: enable MMU */
    msr     sctlr_el2, x0
    isb

    ret
