/* Minimal AArch64 EL2 identity-map MMU setup for BCM2712 (Raspberry Pi 5)
   bare-metal code -- GitHub issue #165, the RPi5-specific follow-up to the
   general MMU work in issue #67. Ports examples/common_rpi3/mmu.S's own
   identity-map idea (see that file's header comment for the full original
   derivation), simplified because BCM2712's physical map, unlike
   BCM2837's, has RAM and every MMIO region this code touches on SEPARATE
   1GB-aligned boundaries far apart from each other -- so this file needs
   only L1 BLOCK descriptors (1GB granularity), no L2/L3 tables at all.

   Why this exists at all: examples/packed (deliberately misaligned struct
   field access) and examples/common/inet_checksum.tkb (unaligned 16-bit
   wire reads) both hung on real RPi5 hardware with ESR_EL2=0x96000061 --
   a same-EL Data Abort, DFSC=Alignment fault -- confirmed via reading
   ESR_EL2/ELR_EL2 over SWD after each hang. With the stage-1 MMU
   disabled, AArch64 architecturally treats ALL memory as Device-nGnRnE,
   which enforces natural alignment unconditionally; RPi3 hit this exact
   failure with this exact ESR value early in its own MMU history (see
   examples/common_rpi3/mmu.S's header comment) and it is the reason
   essentially every real bare-metal AArch64 project enables the MMU
   during early boot, not a takibi-specific quirk.

   Three-level 4KB-granule map, T0SZ=27 (37-bit input address -- covers
   every physical address examples/common_rpi5/*.tkb currently
   references, including the RP1 PCIe outbound window's top byte,
   0x1FFFFFFFFF, exactly), starting at level 1 (1GB per L1 entry, same
   starting level as RPi3's 39-bit map): entries are populated only where
   a real access exists; every other entry stays BSS-zeroed (invalid).

     L1[0]        (0x00000000-0x3FFFFFFF): Normal WB Cacheable -- RAM.
     L1[64]       (0x1000000000-0x103FFFFFFF): Device-nGnRnE -- BCM2712's
                  PCIe2 (RP1-attached) root-complex register block
                  examples/common_rpi5/pcie.tkb uses (PCIE_MISC_*, MDIO,
                  EXT_CFG_INDEX/DATA, the RESCAL/GPIO PERST registers).
     L1[65]       (0x1040000000-0x107FFFFFFF): Device-nGnRnE -- covers
                  BCM2712's own on-die uart10 (0x107D001000) and GIC-400
                  (0x107FFF9000/0x107FFFA000) documented in AGENTS.md.
                  The on-die UART remains unused; issue #164 now uses both
                  GIC ranges for RP1 UART0's MIP0 interrupt route. This L1
                  entry was deliberately mapped with issue #165 because
                  RPi3's own history (examples/echo/irq faulting on the
                  separate ARM-Local/QA7 block, see common_rpi3/mmu.S)
                  showed exactly this easy-to-miss adjacent-MMIO gap.
     L1[124..127] (0x1F00000000-0x1FFFFFFFFF): Device-nGnRnE -- the RP1
                  PCIe outbound window examples/common_rpi5/pcie.tkb's
                  pcie2_outbound_window_init programs (CPU physical
                  0x1F00000000, 4GB), which rp1_uart0 (0x1F00030000) and
                  every other RP1-mapped register live inside.

   PS (bits[18:16], max physical address size) = 0b010 (40-bit) -- the
   smallest standard encoding that covers the 37-bit range above (36-bit
   would not). Called from examples/common_rpi5/startup.S's _start,
   AFTER BSS has already been cleared, same ordering requirement and
   reason as RPi3: l1_table lives in .bss, so the ordinary BSS-clear loop
   is what zeroes it to "no entries valid" before this code populates the
   ones it actually uses. */
    .section .bss
    .align  12              /* 4KB alignment, required for a translation
                                table base address */
l1_table:
    .space  4096

    .section .text
    .global mmu_init
mmu_init:
    adrp    x1, l1_table
    add     x1, x1, :lo12:l1_table

    /* L1[0]: RAM, Normal WB Cacheable. Block descriptor: AttrIndx 1 (bit
       2, MAIR_EL2 byte 1) | AF (bit 10) | SH=11 Inner Shareable (bits
       9:8) | valid+block (bits 1:0) = 0x705, output address 0 (identity).
       Same encoding as RPi3's own L2 Normal entries -- L1 and L2 block
       descriptors share the same attribute-field layout. */
    mov     x4, #0x705
    str     x4, [x1]

    /* L1[64] and L1[65]: BCM2712 MMIO, Device-nGnRnE. AttrIndx 0 | AF |
       SH=00 Non-shareable | valid+block = 0x401, output address =
       index << 30 (identity, 1GB-aligned). x3 built via a plain
       shifted-register ORR (not an ORR-immediate), so there is no
       bitmask-encodability concern combining an arbitrary block index
       with the fixed 0x401 attribute word. */
    mov     x2, #64
    lsl     x3, x2, #30
    mov     x4, #0x401
    orr     x4, x4, x3
    str     x4, [x1, x2, lsl #3]

    mov     x2, #65
    lsl     x3, x2, #30
    mov     x4, #0x401
    orr     x4, x4, x3
    str     x4, [x1, x2, lsl #3]

    /* L1[124..127]: RP1 PCIe outbound window, Device-nGnRnE, same
       encoding as above, looped since it is four contiguous 1GB blocks. */
    mov     x2, #124
    mov     x6, #128                /* one past the last entry */
.Lrp1_loop:
    cmp     x2, x6
    b.ge    .Lrp1_done
    lsl     x3, x2, #30
    mov     x4, #0x401
    orr     x4, x4, x3
    str     x4, [x1, x2, lsl #3]
    add     x2, x2, #1
    b       .Lrp1_loop
.Lrp1_done:

    /* MAIR_EL2: byte 0 (AttrIndx 0) = 0x00 Device-nGnRnE; byte 1
       (AttrIndx 1) = 0xFF Normal, Inner/Outer Write-Back
       Read/Write-Allocate Cacheable. Identical to RPi3's own value. */
    movz    x0, #0xff00
    msr     mair_el2, x0

    /* TCR_EL2 = 0x8082351B: T0SZ=27 (bits 5:0, 37-bit input address),
       IRGN0=01 Write-Back RA/WA (bits 9:8), ORGN0=01 (bits 11:10),
       SH0=11 Inner Shareable (bits 13:12), TG0=00 4KB granule (bits
       15:14), PS=010 40-bit (bits 18:16), plus the two
       architecturally-RES1 bits (23, 31) -- same layout as RPi3's own
       TCR_EL2 (confirmed by recomputing RPi3's known-good 0x80803519
       from the same formula with T0SZ=25/PS=000 before deriving this
       value), safe to reuse verbatim because a live-hardware probe
       (2026-07-25, examples/common_rpi5/AGENTS.md) read HCR_EL2=
       0x0000000080000000 on this exact boot path -- bit 34 (E2H) clear,
       so Trusted Firmware-A hands off to a takibi payload WITHOUT VHE
       active, meaning TCR_EL2 uses the same "basic" (non-VHE) field
       layout RPi3's Cortex-A53 always used, not the VHE/TCR_EL1-shaped
       alternate layout that would apply if E2H were set. */
    movz    x0, #0x351b
    movk    x0, #0x8082, lsl #16
    msr     tcr_el2, x0

    adrp    x0, l1_table
    add     x0, x0, :lo12:l1_table
    msr     ttbr0_el2, x0

    isb
    dsb     sy

    /* Invalidate any stale TLB entries from a previous occupant of this
       core before enabling translation -- same reasoning as RPi3's
       mmu_init: a JTAG-re-injected payload inherits system-register/TLB
       state from whatever ran here before, not a reset. */
    tlbi    alle2
    dsb     sy
    isb

    /* Enable the MMU (SCTLR_EL2.M) and both caches (C, I) -- GitHub
       issue #169. An EARLIER version of this function enabled M only,
       leaving C/I off: real-hardware testing during issue #165 (the
       original MMU milestone) found that enabling I-cache broke
       examples/common_rpi5/pcie.tkb's own link-training/PHY/reset
       delays, which used to be plain empty-loop iteration counts
       calibrated for cache-off execution speed (not a real timer read)
       -- with I-cache on, the CPU retires the same fixed instruction
       count far faster in wall-clock time, so the real PCIe hardware
       timing requirement (link settle time, PHY lock, PERST-deassert-
       to-access delay) stopped being honored and link training silently
       failed (confirmed directly: FR register reads back 0xDEADDEAD,
       the classic PCIe-poison pattern, with caches on). Issue #169 fixed
       the actual root cause instead of leaving caches off permanently:
       pcie.tkb's delays are now real ARM-Generic-Timer waits
       (delay_us()/timed_out(), examples/common_rpi5/timer_asm.S's
       read_cntfrq/read_cntpct), immune to execution speed by
       construction, so re-enabling C/I here no longer breaks PCIe
       bring-up -- confirmed via a full real-hardware make hwcheck-rpi5
       run, multiple times in a row, with both caches on.
       No Cortex-A53-style CPUECTLR_EL1.SMPEN step here (unlike RPi3's
       mmu_init): that bit is an A53/A57-generation implementation detail
       for opting a core into the cluster's coherency domain before
       enabling its D-cache, and RPi5's Cortex-A76 does not need it --
       only core 0 runs today (no RPi5 SMP example exists yet, see issue
       #163), so this has not been exercised against multi-core cache
       coherence the way RPi3's own smp_handoff hardware run originally
       motivated that step; revisit if a future RPi5 SMP example finds
       otherwise. startup.S's _start already unconditionally invalidates
       the entire D-cache (by set/way) and I-cache before this function
       even runs, for the same stale-cache-line-from-a-previous-JTAG-
       injection reason RPi3's own startup.S documents, so it is safe to
       turn both on here as the new steady state. */
    mrs     x0, sctlr_el2
    orr     x0, x0, #(1 << 2)        /* SCTLR_EL2.C: enable D-cache */
    orr     x0, x0, #(1 << 12)       /* SCTLR_EL2.I: enable I-cache */
    orr     x0, x0, #1               /* SCTLR_EL2.M: enable MMU */
    msr     sctlr_el2, x0
    isb

    ret
