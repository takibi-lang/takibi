/* EL2 -> EL1 drop for RPi5 (GitHub issue #163's next-step follow-up) --
   port of examples/common_rpi3/el1_asm.S's own proven mechanism, adapted
   to BCM2712: reuse the EL2 identity map examples/common_rpi5/mmu.S's
   mmu_init already built as EL1&0's own stage 1 translation regime, then
   eret into ordinary Takibi code running at EL1. See that RPi3 file's
   own header comment for the full architectural rationale (EL1&0's
   TTBR0_EL1/TCR_EL1/MAIR_EL1/SCTLR_EL1 is a completely separate register
   file from EL2's own, no VHE sharing on either board's core -- BCM2837
   is ARMv8.0 with no VHE at all; BCM2712's Cortex-A76 does support VHE
   but examples/common_rpi5/AGENTS.md already confirmed live, via a
   direct HCR_EL2 register probe, that TF-A hands off with E2H clear, so
   this code runs in the same non-VHE EL1&0 regime RPi3 does -- VHE is
   simply unused here, not absent from the hardware).

   Naming: called rpi5_el1_enter, NOT a shared/generic name, deliberately
   mirroring RPi3's own rpi3_el1_enter -- that symbol is called from five
   different RPi3 files (el1_smoke/hvc_smoke/el0_smoke/el0_shell/
   el0_elf_load) and is not a portable public HAL function the way
   uart_puts/rtc_init are, so renaming it to something shared would touch
   proven RPi3 code for no real benefit. examples/el1_smoke/
   el1_smoke_rpi5.tkb is therefore its own small RPi5-specific file, not
   a reuse of examples/el1_smoke/el1_smoke.tkb (which hardcodes
   `use "examples/common_rpi3/el1_asm_extern.tkb"`). */
    .section .text

/* Minimal EL1 exception vector table (2KB aligned) -- every entry just
   spins, same reasoning as examples/common_rpi5/startup.S's own EL2
   table (and RPi3's own EL1 table): a spin at a known PC, inspectable
   over SWD, beats an unhandled fault running off into whatever VBAR_EL1
   held before this code ever set it. No real EL1 exception handling and
   no EL0 vector wiring exist yet -- this milestone only proves the
   EL2->EL1 drop itself, the same narrow scope RPi3's own el1_smoke
   started from. */
    .align  11
rpi5_el1_vectors:
    b       .                   /* 0x000: Synchronous (EL1t) */
    .align  7
    b       .                   /* 0x080: IRQ */
    .align  7
    b       .                   /* 0x100: FIQ */
    .align  7
    b       .                   /* 0x180: SError */
    .align  7
    b       .                   /* 0x200: Synchronous (EL1h) */
    .align  7
    b       .                   /* 0x280: IRQ */
    .align  7
    b       .                   /* 0x300: FIQ */
    .align  7
    b       .                   /* 0x380: SError */
    .align  7
    b       .                   /* 0x400: Synchronous (lower EL, AArch64) */
    .align  7
    b       .                   /* 0x480: IRQ */
    .align  7
    b       .                   /* 0x500: FIQ */
    .align  7
    b       .                   /* 0x580: SError */
    .align  7
    b       .                   /* 0x600: Synchronous (lower EL, AArch32) */
    .align  7
    b       .                   /* 0x680: IRQ */
    .align  7
    b       .                   /* 0x700: FIQ */
    .align  7
    b       .                   /* 0x780: SError */

/* void rpi5_el1_enter(usize el1_sp) -- never returns to its caller (the
   caller is left behind at EL2 permanently; only a subsequent IRQ routed
   to EL2 by HCR_EL2.IMO, already set unconditionally by startup.S for
   issue #164's UART0 RX path, would ever run EL2 code again -- not
   exercised by this milestone, since el1_main here never enables RX).
   x0 = stack pointer to install as SP_EL1 before entry. */
    .global rpi5_el1_enter
rpi5_el1_enter:
    /* TTBR0_EL1 := TTBR0_EL2 (reuse the live EL2 identity map -- see
       this file's header comment for why reusing the raw table content
       is safe: every existing page's AP encoding carries over unchanged
       in meaning under the EL1&0 regime, same as RPi3's own reasoning). */
    mrs     x2, ttbr0_el2
    msr     ttbr0_el1, x2

    /* TCR_EL1: same T0SZ=27/IRGN0/ORGN0/SH0/TG0 low-order bits as
       examples/common_rpi5/mmu.S's own TCR_EL2 value 0x8082351b (see
       that file's own comment for the per-field breakdown -- 0x351b is
       the shared low part), plus EPD1 (bit 23) so a TTBR1 walk -- never
       programmed, this kernel has no higher-half mapping -- faults
       cleanly instead of walking garbage. Not the same bit as TCR_EL2's
       own RES1 bit 23: TCR_EL1 bit 23 is architecturally EPD1, a real
       control bit that coincides with TCR_EL2's fixed-1 bit position by
       coincidence, not by shared meaning (identical distinction RPi3's
       own el1_asm.S documents).

       UNLIKE RPi3's el1_asm.S, this ALSO sets TCR_EL1.IPS (bits[34:32],
       Intermediate Physical Address Size) to 0b010 (40-bit), matching
       TCR_EL2's own PS field in mmu.S. Found the hard way on real
       hardware: RPi3's TCR_EL1 never sets an IPS-equivalent field
       because BCM2837 only ever needs 32-bit PA (TCR_EL2.PS=000 there
       too), but BCM2712's own l1_table has real block descriptors with
       output addresses at 0x10_xxxxxxxx and 0x1F_xxxxxxxx (the PCIe2
       register block and RP1 outbound window) -- both well beyond a
       32-bit/4GB boundary. Leaving TCR_EL1.IPS at its default (0,
       32-bit) while TTBR0_EL1 reuses TTBR0_EL2's SAME table content
       made EL1's own translation regime reject those same L1 block
       descriptors as exceeding its configured PA size the moment
       el1_main's first uart_putc() call walked through L1[124]: real
       hardware confirmed ESR_EL1=0x96000001 (EC=0x25 same-EL Data
       Abort, DFSC=0b000001 "Address size fault, level 1"),
       ELR_EL1 pointing inside uart_putc itself -- a real, reproducible
       hang caught via examples/el1_smoke's own hwcheck-rpi5 fixture
       (only "el1_smoke\n" from EL2 printed, "hello from EL1\n" never
       arrived) before this fix. IPS=0b010 (40-bit) is encoded via a
       second movk into the [47:32] lane, since bits 34:32 fall outside
       the first 16-bit immediate lane movz/orr can reach. */
    movz    x2, #0x351b
    orr     x2, x2, #(1 << 23)
    movk    x2, #0x2, lsl #32
    msr     tcr_el1, x2

    /* MAIR_EL1: identical encoding to mmu.S's MAIR_EL2, so the same
       value applies unchanged -- AttrIndx 0 = Device-nGnRnE, AttrIndx 1
       = Normal Write-Back Cacheable. */
    movz    x2, #0xff00
    msr     mair_el1, x2

    adrp    x2, rpi5_el1_vectors
    add     x2, x2, :lo12:rpi5_el1_vectors
    msr     vbar_el1, x2
    isb

    /* No stale TLB entries can exist for ASID/regime EL1&0 yet (first
       time TTBR0_EL1 has ever been programmed on this core since the
       last reset/power-cycle), but invalidate before enabling the MMU
       anyway -- cheap, matches mmu_init's own defensive tlbi for EL2. */
    tlbi    vmalle1
    dsb     ish
    isb

    /* SCTLR_EL1: read-modify-write (like startup.S's own SCTLR_EL2
       setup) so any implementation-defined RES1 bits this SoC's reset
       value already carries are preserved. Enable M (MMU); leave C
       (D-cache) and I (I-cache) OFF, matching mmu.S's own current EL2
       steady state for this exact same reason (issue #169: enabling
       caches broke pcie.tkb's iteration-count delay loops -- irrelevant
       to el1_main here, which touches no PCIe/RP1 registers at all, but
       keeping EL1's cache policy consistent with EL2's avoids a subtle,
       needless divergence for no benefit this milestone needs). Clear A
       (alignment-fault checking) to match EL2's own setting. */
    mrs     x2, sctlr_el1
    orr     x2, x2, #1
    bic     x2, x2, #(1 << 2)
    bic     x2, x2, #(1 << 12)
    bic     x2, x2, #(1 << 1)
    msr     sctlr_el1, x2
    isb

    msr     sp_el1, x0

    /* HCR_EL2.RW (bit 31): "EL1 executes in AArch64 state". Read-modify-
       write, NOT a blind overwrite -- this preserves HCR_EL2.IMO (bit 4),
       already set unconditionally by startup.S for issue #164's UART0 RX
       path, and every other inherited bit. Confirmed the hard way on
       RPi3 (see that board's own el1_asm.S comment): without RW set,
       `eret` to an AArch64 EL1h target is an illegal exception return
       and never switches levels at all. */
    mrs     x2, hcr_el2
    orr     x2, x2, #(1 << 31)
    /* HCR_EL2.HCD (bit 29, Hypervisor Call Disable): clear it
       preemptively, same "don't trust inherited system-register state"
       discipline as RW above -- no RPi5 example calls `hvc` yet, but
       this costs nothing and avoids a surprise if one does later. */
    bic     x2, x2, #(1 << 29)
    msr     hcr_el2, x2

    /* CPTR_EL2.TFP (bit 10, Trap Floating Point): clear preemptively so
       EL2 never traps EL1 FP/SIMD access -- same discipline as RPi3's
       own el1_asm.S, not empirically required yet on this board (no
       RPi5 example uses FP/SIMD), added anyway to not depend on the
       inherited value. */
    mrs     x2, cptr_el2
    bic     x2, x2, #(1 << 10)
    msr     cptr_el2, x2

    /* SPSR_EL2: target EL1h (M[3:0] = 0b0101), DAIF all masked -- this
       milestone does not handle interrupts or exceptions at EL1 (see
       rpi5_el1_vectors above; real EL1 exception/IRQ handling is future
       work, not this smoke test). */
    movz    x2, #0x3c5
    msr     spsr_el2, x2
    adr     x2, .Lel1_entry
    msr     elr_el2, x2
    eret

.Lel1_entry:
    /* Now executing at EL1h with SP = SP_EL1. Ordinary AAPCS64 call into
       Takibi code -- el1_main is defined in the example's own .tkb
       file, same pattern as startup.S's own `bl main` handoff to
       app-level Takibi code at EL2. */
    bl      el1_main
.Lel1_park:
    wfe
    b       .Lel1_park
