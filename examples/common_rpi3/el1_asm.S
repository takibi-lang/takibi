/* EL2 -> EL1 drop (GitHub issue #153 Stage 1): reuse the EL2 identity map
   already built by mmu.S's mmu_init as EL1&0's own stage 1 translation
   regime, then eret into ordinary Takibi code running at EL1.

   EL1&0's stage 1 (TTBR0_EL1/TCR_EL1/MAIR_EL1/SCTLR_EL1) is a completely
   separate register file from EL2's own (TTBR0_EL2/TCR_EL2/MAIR_EL2/
   SCTLR_EL2, see mmu.S) -- there is no sharing mechanism on this hardware
   (BCM2837 is Cortex-A53, ARMv8.0-A; VHE, which would let EL2 reuse EL1
   registers directly, is ARMv8.1+ and not implemented here). Landing at
   EL1 without configuring EL1's own regime would leave SCTLR_EL1.M at its
   inherited/reset value (MMU off), reintroducing exactly the
   unaligned-store miscompilation hazard mmu.S's own header comment
   documents for EL2 (see examples/packed, examples/inet_checksum) -- so
   EL1's own MMU must come up as part of this same transition, not as a
   separate later step.

   Only the TRANSLATION TABLE is reused (TTBR0_EL1 := TTBR0_EL2's current
   value, the exact same physical L1/L2/L3 tables mmu.S already built and
   populated). Every existing page's AP[2:1] encoding happens to carry
   over unchanged in meaning: EL2's own stage 1 AP[2] bit (0 = RW, 1 = RO,
   AP[1] unused/RES0 in EL2's regime) maps onto the EL1&0 regime's AP[2:1]
   encoding (00 = EL1 RW/EL0 none, 10 = EL1 RO/EL0 none) at the same bit
   positions -- every entry mmu.S/vm_page_map_core.tkb wrote with AP[1]=0
   therefore keeps its EL2 meaning ("privileged access only") unchanged
   when reinterpreted under EL1&0, with EL0 access staying denied until a
   future change deliberately sets AP[1]=1 on a page meant to be
   EL0-accessible (not needed yet -- no EL0 code runs in this milestone). */
    .section .text

/* Minimal EL1 exception vector table (2KB aligned) -- every entry just
   spins, same reasoning as startup.S's own EL2 table: a spin at a known
   PC, inspectable over JTAG, beats an unhandled fault running off into
   whatever VBAR_EL1 held before this code ever set it (inherited firmware/
   previous-run state, since JTAG re-injection does not reset system
   registers -- see startup.S's own comment on this). No real EL1 exception
   handling exists yet; this exists purely so a bug during bring-up parks
   predictably instead of corrupting state badly enough to lose the debug
   session too. */
    .align  11
el1_vectors:
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
    b       el0_sync_entry      /* 0x400: Synchronous (lower EL, AArch64) --
                                    GitHub issue #153: real SVC entry once
                                    an example drops further to EL0 */
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

/* void rpi3_el1_enter(usize el1_sp) -- never returns to its caller (the
   caller is left behind at EL2 permanently; only a subsequent IRQ routed
   to EL2 -- not yet exercised in this milestone, HCR_EL2.IMO is still set
   from startup.S -- would ever run EL2 code again). x0 = stack pointer to
   install as SP_EL1 before entry. */
    .global rpi3_el1_enter
rpi3_el1_enter:
    /* TTBR0_EL1 := TTBR0_EL2 (reuse the live EL2 identity map -- see this
       file's header comment for why reusing the raw table content is
       safe). */
    mrs     x2, ttbr0_el2
    msr     ttbr0_el1, x2

    /* TCR_EL1: same T0SZ/IRGN0/ORGN0/SH0/TG0/PS low-order bits as
       mmu.S's TCR_EL2 value 0x80803519 (see its own comment for the
       per-field breakdown -- 0x3519 is the shared low part), plus EPD1
       (bit 23) so a TTBR1 walk -- never programmed, since this kernel
       has no higher-half mapping -- faults cleanly instead of walking
       garbage. This is NOT the same bit as TCR_EL2's own RES1 bit 23:
       TCR_EL1 bit 23 is architecturally EPD1, a real control bit that
       coincides with TCR_EL2's fixed-1 bit position by coincidence, not
       by shared meaning. TCR_EL2's bit 31 RES1 has no TCR_EL1
       counterpart and is correctly left unset here. */
    movz    x2, #0x3519
    orr     x2, x2, #(1 << 23)
    msr     tcr_el1, x2

    /* MAIR_EL1: identical encoding to MAIR_EL2 (mmu.S), so the same
       value applies unchanged -- AttrIndx 0 = Device-nGnRnE, AttrIndx 1
       = Normal Write-Back Cacheable. */
    movz    x2, #0xff00
    msr     mair_el1, x2

    adrp    x2, el1_vectors
    add     x2, x2, :lo12:el1_vectors
    msr     vbar_el1, x2
    isb

    /* No stale TLB entries can exist for ASID/regime EL1&0 yet (this is
       the first time TTBR0_EL1 has ever been programmed on this core
       since the last full reset/power-cycle), but invalidate before
       enabling the MMU anyway -- cheap, and matches mmu_init's own
       defensive tlbi before its first use for EL2. */
    tlbi    vmalle1
    dsb     ish
    isb

    /* SCTLR_EL1: read-modify-write (like startup.S's own SCTLR_EL2 setup)
       rather than a blind immediate, so any implementation-defined RES1
       bits this SoC's reset value already carries are preserved. Enable
       M (MMU)/C (D-cache)/I (I-cache); clear A (alignment-fault checking)
       to match the EL2 setting every other RPi3 example already relies
       on (see startup.S's own comment on why: LLVM's store-merging
       optimization can synthesize a wider-than-source-level-aligned
       store even from correctly-aligned .tkb source). */
    mrs     x2, sctlr_el1
    orr     x2, x2, #1
    orr     x2, x2, #(1 << 2)
    orr     x2, x2, #(1 << 12)
    bic     x2, x2, #(1 << 1)
    msr     sctlr_el1, x2
    isb

    msr     sp_el1, x0

    /* HCR_EL2.RW (bit 31): "EL1 executes in AArch64 state". Left at
       whatever the GPU firmware/ARM Trusted Firmware handoff or a
       previous JTAG-injected run left it as (same inherited-state
       caveat as every other system register here, see startup.S's own
       comment) -- nothing in this codebase ever needed it before, since
       no code ever ran below EL2. Confirmed the hard way: without this,
       `eret` to an AArch64 EL1h target is an illegal exception return
       (target execution state does not match RW's AArch32-EL1
       configuration), which does not switch levels at all -- it sets
       PSTATE.IL and immediately raises a synchronous "Illegal Execution
       state" exception (ESR_EL2 EC 0x0E) back at EL2, caught by the
       existing rpi3_exception_unhandled spin (confirmed via a live
       OpenOCD halt+register read: ESR_EL2 0x3a000000, ELR_EL2 pointing
       at this very `eret`, SPSR_EL2's saved PSTATE showing IL set and
       M[3:0] still EL2h -- the level transition never took effect). */
    mrs     x2, hcr_el2
    orr     x2, x2, #(1 << 31)
    /* HCR_EL2.HCD (bit 29, Hypervisor Call Disable): clear it explicitly
       so `hvc` from EL1 (GitHub issue #154) is never accidentally
       trapped as an undefined instruction because of whatever this bit's
       inherited value happened to be -- same "don't trust inherited
       system-register state" discipline as HCR_EL2.RW just above,
       applied preemptively this time rather than after a live-hardware
       surprise. */
    bic     x2, x2, #(1 << 29)
    msr     hcr_el2, x2

    /* CPTR_EL2.TFP (bit 10, Trap Floating Point): clear preemptively so
       EL2 never re-traps EL1/EL0 FP/SIMD access even if CPACR_EL1 grants
       it below -- same "don't trust inherited register state" discipline
       as HCR_EL2.HCD just above. Not empirically required (the FP trap
       GitHub issue #156's real busybox-static target hit landed at EL1,
       proving this bit was already clear on this hardware/firmware
       combination), added anyway to not depend on that inherited value
       staying that way. */
    mrs     x2, cptr_el2
    bic     x2, x2, #(1 << 10)
    msr     cptr_el2, x2

    /* SPSR_EL2: target EL1h (M[3:0] = 0b0101), DAIF all masked -- this
       milestone does not yet handle interrupts or exceptions at EL1
       (see el1_vectors above; a real IRQ/exception design is future
       work, not this smoke test). */
    movz    x2, #0x3c5
    msr     spsr_el2, x2
    adr     x2, .Lel1_entry
    msr     elr_el2, x2
    eret

.Lel1_entry:
    /* CPACR_EL1.FPEN (bits 21:20) = 0b11: EL0 and EL1 both get
       unrestricted FP/SIMD access. Never needed before this (every
       hand-written test payload in this repo deliberately avoided
       FP/SIMD instructions), until GitHub issue #156's real
       busybox-static target -- an ordinary compiler-generated binary
       whose own crt/self-relocation code uses vectorized memcpy very
       early. Confirmed the hard way via a live OpenOCD halt+register
       read: without this, the first such instruction traps with
       ESR_EL1 0x1fe00000 (EC bits [31:26] = 0x07, "Access to SVE,
       Advanced SIMD, or floating-point functionality trapped"),
       ELR_EL1 pointing partway into the loaded binary's own code --
       caught by el0_svc_dispatch's EC!=0x15 fallthrough straight into
       rpi3_exception_unhandled's silent spin, with no further UART
       output at all (indistinguishable from a hang without this
       register read). */
    mrs     x0, cpacr_el1
    orr     x0, x0, #(0x3 << 20)
    msr     cpacr_el1, x0
    isb

    /* Now executing at EL1h with SP = SP_EL1. Ordinary AAPCS64 call into
       Takibi code -- el1_main is defined in the example's own .tkb file,
       same pattern as startup.S's own `bl rpi3_boot_main`. */
    bl      el1_main
.Lel1_park:
    wfe
    b       .Lel1_park

/* -- Default (no-op) EL0 synchronous-exception entry -----------------------
   el1_vectors' Lower-EL-AArch64-Synchronous entry branches here
   unconditionally, same as startup.S's own weak rpi3_irq_dispatch/
   rpi3_sync_exception_dispatch defaults -- an example that never drops to
   EL0 (like el1_smoke) still needs this symbol to resolve at link time.
   examples/common_rpi3/el0_asm.S provides the strong override (real SVC
   register-frame save + el0_svc_dispatch call) for any example that
   actually calls rpi3_el0_enter (GitHub issue #153). */
    .weak   el0_sync_entry
el0_sync_entry:
    b       .
