/* Raspberry Pi 5 (BCM2712) bare-metal startup. Issue #164 adds the one
   exception path now required beyond issue #161's polling milestone: the
   Current-EL-SPx IRQ slot saves a full interrupted frame and calls the weak
   rpi5_irq_dispatch hook, overridden by common_rpi5/intc.tkb for RP1 UART0.
   HVC/EL1/EL0 and unrelated exception paths remain deliberately absent.

   Like RPi3, this image is never booted from the SD card directly. The SD
   card carries jtag_stub.img (this directory's jtag_stub.S), a tiny spin
   loop the RPi5 boot chain (EEPROM -> TF-A BL31, which hands off 64-bit
   payloads at EL2 per Trusted Firmware-A's own rpi5 platform docs) reaches
   first; OpenOCD then halts core 0, `load_image`s this file's linked ELF,
   pokes PC/SP, and resumes -- see scripts/rpi5_jtag_load.sh. The official
   Debug Probe's SWD connection has no usable nSRST line on this board;
   scripts/rpi5_jtag_reset.sh uses PSCI SYSTEM_RESET and documents its
   same-resident-image limitation. */
    .section .text.boot

/* Same architecture-generic ARMv8-A CLIDR_EL1/CSSELR_EL1/CCSIDR_EL1
   set/way sweep as examples/common_rpi3/startup.S's own routine of this
   name (see that file's header comment for the full derivation) -- nothing
   here is BCM2837-specific, so it is copied verbatim rather than shared,
   matching this codebase's existing per-target duplication convention
   (examples/common_rpi3/print.tkb is itself a byte-for-byte copy of
   examples/common_qemu/print.tkb for the same reason). Leaf routine: safe
   to `bl` before SP is initialised. Clobbers x0-x12. */
    .global dcache_invalidate_all
dcache_invalidate_all:
    mrs     x0, clidr_el1
    and     x3, x0, #0x7000000      /* x3 = LoC field (bits 26:24) */
    lsr     x3, x3, #23              /* x3 = LoC * 2 */
    cbz     x3, .Ldcache_done
    mov     x10, #0                  /* x10 = 2 * current cache level */
.Ldcache_level_loop:
    add     x2, x10, x10, lsr #1     /* x2 = 3 * level, indexes Ctype */
    lsr     x1, x0, x2
    and     x1, x1, #7               /* x1 = Ctype for this level */
    cmp     x1, #2
    b.lt    .Ldcache_skip            /* Ctype < 2: no data cache here */
    msr     csselr_el1, x10          /* select this level/type */
    isb
    mrs     x1, ccsidr_el1
    and     x2, x1, #7
    add     x2, x2, #4               /* x2 = log2(line size in bytes) */
    ubfx    x4, x1, #3, #10          /* x4 = associativity - 1 */
    clz     w5, w4                   /* x5 = way field's bit position */
    mov     x7, #0                   /* x7 = way counter */
.Ldcache_way_loop:
    ubfx    x9, x1, #13, #15         /* x9 = number of sets - 1 */
    mov     x6, #0                   /* x6 = set counter */
.Ldcache_set_loop:
    lsl     x11, x7, x5
    orr     x11, x10, x11            /* level | way */
    lsl     x12, x6, x2
    orr     x11, x11, x12            /* | set */
    dc      isw, x11
    add     x6, x6, #1
    cmp     x6, x9
    b.le    .Ldcache_set_loop
    add     x7, x7, #1
    cmp     x7, x4
    b.le    .Ldcache_way_loop
.Ldcache_skip:
    add     x10, x10, #2
    cmp     x3, x10
    b.gt    .Ldcache_level_loop
.Ldcache_done:
    dsb     sy
    ret

    .global _start
_start:
    /* Only core 0 runs main(). GitHub issue #163: the BCM2837-by-analogy
       assumption this comment used to make -- that MPIDR_EL1's Aff0
       field (bits[7:0]) is the plain 0-3 core number, same as RPi3 --
       was WRONG and is now corrected, based on real hardware evidence
       (read via OpenOCD's per-core `bcm2712.cpu0`..`cpu3` targets,
       redirecting each core's PC to a tiny `mrs x0, mpidr_el1; wfe`
       probe in scratch RAM and single-stepping it, then restoring the
       original PC before resuming -- never touching TF-A's own EL3 code
       or state, only reading a register). Real captured values:
       cpu0=0x81000000, cpu1=0x81000100, cpu2=0x81000200,
       cpu3=0x81000300 -- Aff0 (bits[7:0]) is 0 on EVERY core, and the
       varying field is Aff1 (bits[15:8]). Bit 24 (MT, "Aff0 describes a
       thread within a core") is set in all four reads, which is exactly
       why: BCM2712 numbers its 4 physical cores in Aff1, treating Aff0
       as a (here always-0, single-thread) thread ID under the MT
       topology encoding, unlike BCM2837's plain flat Aff0 numbering
       RPi3 correctly relies on. The OLD `and x0, x0, #3` therefore
       computed 0 on EVERY core, not just core 0 -- currently
       unobservable only because TF-A never hands off any core but 0 to
       this code (cores 1-3 sit parked in TF-A's own EL3 idle loop,
       confirmed via the same real-hardware read, PC=0x1adc/EL3H on all
       three, never reaching this function at all) -- but it would have
       been a real, serious bug (every core believing it is core 0,
       running main() concurrently) the moment any future milestone
       used PSCI CPU_ON to actually release a secondary core here. Fixed
       to extract Aff1 instead: shift right 8, then mask to 2 bits (safe
       since this SoC has exactly 4 cores, values 0-3 only). */
    mrs     x0, mpidr_el1
    lsr     x0, x0, #8
    and     x0, x0, #3
    cbz     x0, .Lcore0
.Lpark:
    wfe
    b       .Lpark

.Lcore0:
    /* Clear SCTLR_EL2.A/C/I (alignment checking, D-cache, I-cache) before
       trusting any cache state left behind by TF-A or a previous JTAG
       injection this power cycle -- same reasoning as examples/common_rpi3/
       startup.S's identical block. */
    mrs     x0, sctlr_el2
    bic     x0, x0, #(1 << 1)        /* A: alignment-fault checking off */
    bic     x0, x0, #(1 << 2)        /* C: D-cache off, for now */
    bic     x0, x0, #(1 << 12)       /* I: I-cache off, for now */
    msr     sctlr_el2, x0
    isb

    bl      dcache_invalidate_all
    ic      ialluis
    dsb     ish
    isb

    /* Install the exception vector table before anything else can fault --
       same rationale as RPi3: VBAR_EL2 is whatever TF-A left it at, and
       that vector table is not guaranteed to still be valid/mapped once
       our own code has been running. Issue #164 adds the one concrete IRQ
       entry now needed; all unrelated entries retain their debuggable spin. */
    adrp    x0, exception_vectors
    add     x0, x0, :lo12:exception_vectors
    msr     vbar_el2, x0
    isb

    /* Route physical IRQs to EL2. TF-A leaves HCR_EL2.IMO clear for an OS
       that normally receives its interrupts below EL2; this payload stays
       at EL2, so an enabled GIC interrupt would otherwise be implicitly
       masked regardless of PSTATE.I. DAIF.I itself remains masked here:
       common_rpi5/intc.tkb unmasks it only after the concrete UART MSI-X,
       MIP0, and GIC path is fully configured. */
    mrs     x0, hcr_el2
    orr     x0, x0, #0x10
    msr     hcr_el2, x0
    isb

    adrp    x0, stack_top
    add     x0, x0, :lo12:stack_top
    mov     sp, x0

    /* Zero BSS + stack region, same reasoning as examples/common_rpi3/
       startup.S: JTAG re-injection reuses whatever RAM the previous run
       (or TF-A's own boot-time scratch use) left behind, and a
       deterministic all-zero start avoids nondeterministic diffs. */
    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, stack_top
    add     x1, x1, :lo12:stack_top
    cmp     x0, x1
    b.ge    .Lbss_done
.Lbss_loop:
    str     xzr, [x0], #8
    cmp     x0, x1
    b.lt    .Lbss_loop
.Lbss_done:

    /* MMU setup (examples/common_rpi5/mmu.S, GitHub issue #165) MUST run
       AFTER BSS clear, not before: mmu_init's l1_table lives in .bss, so
       the ordinary BSS-clear loop above is what zeroes it to "no entries
       valid" before mmu_init populates the ones it actually uses --
       reversing this order would zero out the live page table mmu_init
       just built, out from under the MMU it just enabled. See mmu.S's
       header comment for why this exists (unaligned-access faults from
       LLVM's own store-merging optimization under Device-memory
       semantics, not from anything a .tkb source does wrong -- the exact
       ESR_EL2=0x96000061 signature RPi3 already hit for the same reason
       early in its own MMU history). */
    bl      mmu_init

    /* DAIF.I remains masked for ordinary examples. The RPi5 interrupt HAL
       enables it from irq_uart_rx_setup() only after all controller state
       is ready and before PL011 IMSC is unmasked. */

    mov     x0, #0
    bl      rpi3_boot_main

.Lhalt:
    wfe
    b       .Lhalt

    .weak   rpi3_boot_main
    .type   rpi3_boot_main, %function
rpi3_boot_main:
    b       main

/* enable_irq()/disable_irq(): same DAIF.I-only mask as
   examples/common_rpi3/startup.S's own pair. klock_guard uses these for
   its giant-lock placeholder; issue #164's interrupt HAL now also calls
   enable_irq after its complete controller path is ready. */
    .global enable_irq
enable_irq:
    msr     DAIFClr, #0x2
    ret

/* Timer HAL-private spelling.  common/rtos.tkb owns the public enable_irq
   extern declaration, so the scheduler HAL uses this alias to remain
   composable with that file without a duplicate extern declaration. */
    .global rpi5_timer_enable_irq
rpi5_timer_enable_irq:
    msr     DAIFClr, #0x2
    ret

    .global disable_irq
disable_irq:
    msr     DAIFSet, #0x2
    ret

/* Default IRQ dispatch for kernels that configure no RPi5-native source.
   The UART builds link a strong rpi5_irq_dispatch from intc.tkb.  The
   scheduler examples already expose the long-established rpi3_irq_dispatch
   hook: forward to it by default so their target-independent tick/switch
   logic can be reused unchanged on RPi5.  A weak same-frame fallback keeps
   ordinary non-interrupt kernels harmless. */
    .weak   rpi5_irq_dispatch
rpi5_irq_dispatch:
    b       rpi3_irq_dispatch

    .weak   rpi3_irq_dispatch
rpi3_irq_dispatch:
    ret

    .weak   rpi3_sync_exception_dispatch
rpi3_sync_exception_dispatch:
    mov     x0, #0
    ret

/* sync_exception_evidence: ESR_EL2/FAR_EL2/ELR_EL2, written by the
   "Current EL SPx, Synchronous" vector slot below before it parks --
   GitHub issue #165's "add useful synchronous-exception evidence instead
   of silent spin-only failure" requirement, applied to the one execution
   level takibi code actually runs at (EL2h, using SP_EL2/SPx) and the one
   already hit for real: both examples/packed and
   examples/common/inet_checksum.tkb hung here with ESR_EL2=0x96000061
   before examples/common_rpi5/mmu.S existed (see that file's header
   comment).

   Kept live in x1/x2/x3 at the final wfe/b halt below, NOT only in this
   memory location -- found the hard way, same session: OpenOCD's `mdw`
   against this exact address reliably returns "Error: abort occurred"
   once the MMU is on (a real, reproducible tooling limitation of this
   CMSIS-DAP/BCM2712/OpenOCD-0.12.0 combination, confirmed by also seeing
   `mdw` fail against ordinary already-mapped low RAM, not anything
   specific to this address), even though `reg`-based register reads
   (general-purpose AND system registers, e.g. `reg x9`, `reg esr_el2`)
   keep working fine with the MMU on. So the reliable read-after-a-hang
   command is `reg x1` / `reg x2` / `reg x3` (ESR/FAR/ELR respectively),
   not `mdw`; sync_exception_evidence itself is kept anyway as a second,
   memory-resident copy for whichever debug path (a future OpenOCD fix,
   a different tool) can actually read it.

   This remains the only synchronous-exception slot with real handling.
   Issue #164 separately adds the Current-EL-SPx IRQ slot; every unrelated
   slot still spins, and takibi still drops to no lower EL. */
    .section .bss
    .align  4
    .global sync_exception_evidence
sync_exception_evidence:
    .space  24

/* Plain .text, not .text.vectors: only the table itself (below) needs
   2KB alignment / the KEEP(*(.text.vectors)) placement link.ld reserves
   right after .text.boot -- this handler is reached by an absolute
   branch from the table, not by falling through, so it has no placement
   constraint of its own and putting a second .text.vectors fragment
   here would just make the table's own 2KB alignment depend on this
   fragment's size threading correctly through the assembler/linker
   merge, which is fragile to reason about for no benefit. */
    .section .text
.Lsync_spx_evidence:
    adrp    x0, sync_exception_evidence
    add     x0, x0, :lo12:sync_exception_evidence
    mrs     x1, esr_el2
    mrs     x2, far_el2
    mrs     x3, elr_el2
    str     x1, [x0]
    str     x2, [x0, #8]
    str     x3, [x0, #16]
.Lsync_spx_halt:
    wfe
    b       .Lsync_spx_halt

/* Default (weak) EL1->EL2 hvc entry: a plain spin, same debuggable-at-a-
   known-PC rationale as every other still-unused vector slot. Every
   RPi5 kernel except examples/hvc_smoke links this weak definition;
   hvc_smoke alone links examples/common_rpi5/hvc_asm.S's strong
   override (the real 272-byte-frame save/dispatch/restore), the same
   weak/strong pattern rpi5_irq_dispatch above already uses. Truly dead
   code for every other example: nothing else ever issues `hvc`. */
    .weak   el1_hvc_entry
el1_hvc_entry:
    b       .

/* -- Exception vector table (must be 2KB aligned) ---------------------------
   A spin at a known PC is inspectable over SWD, so unrelated slots retain
   that behavior. Current-EL-SPx Synchronous (0x200) records fault evidence;
   Current-EL-SPx IRQ (0x280) runs issue #164's saved-frame dispatcher;
   Lower-EL-AArch64 Synchronous (0x400) runs el1_hvc_entry (weak default
   above, or examples/common_rpi5/hvc_asm.S's real handler for
   examples/hvc_smoke). */
    .section .text.vectors
    .align  11
    .global exception_vectors
exception_vectors:
    b       .                   /* 0x000: Current EL SP0, Synchronous */
    .align  7
    b       .                   /* 0x080: Current EL SP0, IRQ */
    .align  7
    b       .                   /* 0x100: Current EL SP0, FIQ */
    .align  7
    b       .                   /* 0x180: Current EL SP0, SError */
    .align  7
    b       rpi5_sync_exception_entry /* 0x200: Current EL SPx, Synchronous */
    .align  7
    b       rpi5_irq_entry      /* 0x280: Current EL SPx, IRQ */
    .align  7
    b       .                   /* 0x300: Current EL SPx, FIQ */
    .align  7
    b       .                   /* 0x380: Current EL SPx, SError */
    .align  7
    b       el1_hvc_entry       /* 0x400: Lower EL AArch64, Synchronous */
    .align  7
    b       .                   /* 0x480: Lower EL AArch64, IRQ */
    .align  7
    b       .                   /* 0x500: Lower EL AArch64, FIQ */
    .align  7
    b       .                   /* 0x580: Lower EL AArch64, SError */
    .align  7
    b       .                   /* 0x600: Lower EL AArch32, Synchronous */
    .align  7
    b       .                   /* 0x680: Lower EL AArch32, IRQ */
    .align  7
    b       .                   /* 0x700: Lower EL AArch32, FIQ */
    .align  7
    b       .                   /* 0x780: Lower EL AArch32, SError */

/* Full x0-x30 + ELR_EL2/SPSR_EL2 save/restore. rpi5_irq_dispatch receives
   the current frame SP and returns the frame SP to resume, matching the
   established QEMU/RPi3 convention even though UART RX always returns the
   same frame today. */
    .section .text
rpi5_irq_entry:
    sub     sp,  sp,  #272
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  x9,  [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    stp     x30, xzr, [sp, #240]
    mrs     x0,  elr_el2
    mrs     x1,  spsr_el2
    stp     x0,  x1,  [sp, #256]

    mov     x0, sp
    bl      rpi5_irq_dispatch
    mov     sp, x0

    ldp     x0,  x1,  [sp, #256]
    msr     elr_el2,  x0
    msr     spsr_el2, x1
    ldp     x0,  x1,  [sp, #0]
    ldp     x2,  x3,  [sp, #16]
    ldp     x4,  x5,  [sp, #32]
    ldp     x6,  x7,  [sp, #48]
    ldp     x8,  x9,  [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldp     x30, xzr, [sp, #240]
    add     sp,  sp,  #272
    eret

/* Complete-frame synchronous exception entry.  A strong Takibi hook may
   repair the fault and return the exact ELR to retry; all other faults keep
   the fail-stop behavior, with ESR/FAR/ELR left in x1/x2/x3 for SWD. */
rpi5_sync_exception_entry:
    sub     sp, sp, #272
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    stp     x30, xzr, [sp, #240]
    mrs     x3, elr_el2
    mrs     x4, spsr_el2
    stp     x3, x4, [sp, #256]
    mrs     x0, esr_el2
    mrs     x1, far_el2
    mov     x2, x3
    mrs     x3, mpidr_el1
    ubfx    x3, x3, #8, #2
    bl      rpi3_sync_exception_dispatch
    ldr     x1, [sp, #256]
    cmp     x0, x1
    b.ne    rpi3_exception_unhandled
    ldp     x0, x1, [sp, #256]
    msr     elr_el2, x0
    msr     spsr_el2, x1
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldp     x30, xzr, [sp, #240]
    add     sp, sp, #272
    eret

    .global rpi3_exception_unhandled
rpi3_exception_unhandled:
    adrp    x0, sync_exception_evidence
    add     x0, x0, :lo12:sync_exception_evidence
    mrs     x1, esr_el2
    mrs     x2, far_el2
    mrs     x3, elr_el2
    str     x1, [x0]
    str     x2, [x0, #8]
    str     x3, [x0, #16]
    b       rpi3_exception_unhandled
