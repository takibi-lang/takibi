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
                  Neither is read by any takibi code yet (uart.tkb targets
                  RP1's PCIe-attached rp1_uart0 instead, and no GIC-driven
                  example exists here yet) -- mapped now anyway, one L1
                  entry, because RPi3's own history (examples/echo/irq
                  faulting on the separate ARM-Local/QA7 block, see
                  examples/common_rpi3/mmu.S) shows exactly this kind of
                  "adjacent but distinct MMIO block, easy to miss" gap is
                  worth closing while already here rather than revisiting
                  this file again for the first RPi5 interrupt example.
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

    /* Enable the MMU (SCTLR_EL2.M) ONLY -- deliberately leave D-cache/
       I-cache (SCTLR_EL2.C/I) OFF, unlike RPi3's mmu_init, which enables
       both. Found the hard way, real hardware, this same session: with
       C/I also enabled, examples/start (and everything else in
       RPI5_EXAMPLES) went completely silent -- platform_init()'s
       pcie2_init() (examples/common_rpi5/pcie.tkb) started returning
       false, so uart_init() never ran, and the FR register read back
       0xDEADDEAD (the same PCIe-link-not-actually-up poison pattern
       documented at length in AGENTS.md) even though the exact same
       code path with caches OFF works every time. Root cause: pcie.tkb's
       own link-training/PHY/reset delays are plain empty-loop iteration
       counts calibrated for cache-off execution speed (its own comments
       say so explicitly -- "~100-200us settle", "~5ms", etc.), not a
       real timer read. Enabling I-cache makes the CPU retire that same
       fixed instruction count far faster in wall-clock time, so the
       real PCIe hardware requirement (link settle time, PHY lock, PERST
       deassert-to-access delay) stops actually being honored, and link
       training silently fails. Confirmed directly: reading back x9
       (uart_putc's locally-cached FR value) over SWD showed the classic
       0xDEADDEAD PCIe-poison pattern with caches on, and the exact same
       build with only the two `orr` lines below removed produces the
       correct "foo(5)=1\r\nbar(3,4)=0\r\nbar(1,10)=1\r\n" output.
       MMU-alone (M bit) is sufficient for this issue's actual
       requirement -- the "unaligned access always faults" rule is tied
       to Device vs Normal MEMORY TYPE under stage-1 translation, not to
       whether caching is actually active, so Normal memory with caching
       still off (this file's l1_table entry 0) already exempts RAM from
       that rule. Revisit enabling C/I together as a SEPARATE, later
       change once examples/common_rpi5/pcie.tkb's delays are rewritten
       against a real timer (BCM2712's ARM Generic Timer, same source
       examples/common_rpi3/rtc.tkb already reads) instead of iteration
       counts -- not in this issue's scope, which is the MMU/exception
       path only. No Cortex-A53-style CPUECTLR_EL1.SMPEN step either
       (unlike RPi3's mmu_init): that bit is an A53/A57-generation detail
       for joining the cluster's coherency domain before enabling
       D-cache, moot here since D-cache stays off and only core 0 runs
       today (no RPi5 SMP example exists yet, issue #163). */
    mrs     x0, sctlr_el2
    orr     x0, x0, #1               /* SCTLR_EL2.M: enable MMU */
    msr     sctlr_el2, x0
    isb

    ret
