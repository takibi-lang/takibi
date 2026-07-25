/* Raspberry Pi 5 (BCM2712) bare-metal startup -- Stage A (RP1 PCIe + UART
   polling, GitHub issue #161). Deliberately much smaller than
   examples/common_rpi3/startup.S: no MMU, no HVC/EL1/EL0 vectors, no IRQ
   routing. Those were all added to the RPi3 file over many later hardening
   passes; porting all of them here before a single byte has ever reached
   real RPi5 hardware would mean debugging several unproven mechanisms at
   once. Add each piece back only once a concrete example needs it, mirroring
   how examples/common_rpi3/startup.S itself grew one milestone at a time --
   see examples/common_rpi5/AGENTS.md for the sourced facts (UART address,
   EL2 handoff, GIC-400 presence, etc.) this file's assumptions rest on.

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
    /* Only core 0 runs main(). BCM2712 is a single-cluster quad-A76 part
       like BCM2837's single-cluster quad-A53, so MPIDR_EL1's Aff0 field
       (bits[1:0] here, same as RPi3) is assumed to still be the plain
       0-3 core number -- UNCONFIRMED, first thing to check via OpenOCD's
       per-core `bcm2712.cpu0`..`cpu3` targets if core selection ever looks
       wrong. The loader may use cpu3's debug context to write shared RAM,
       but only cpu0's PC/SP are redirected to this payload; this gate remains
       defensive/for-parity-with-RPi3 rather than load-bearing yet. */
    mrs     x0, mpidr_el1
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
       our own code has been running. Every entry just spins (a debuggable,
       known PC over SWD), not real dispatch -- add real handling only once
       a concrete example needs it (RPi3's own history: IRQ/HVC/EL0 vectors
       were each added in later, separate milestones, not all at once). */
    adrp    x0, exception_vectors
    add     x0, x0, :lo12:exception_vectors
    msr     vbar_el2, x0
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

    /* No mmu_init call yet (unlike RPi3): Stage A runs entirely with the
       EL2 stage 1 MMU off, so every address examples/common_rpi5/uart.tkb
       uses is a real physical address. Add a dynamic/identity MMU setup
       (examples/common_rpi3/mmu.S's pattern) only once a concrete example
       actually needs it, same incremental order RPi3 itself followed. */

    /* IRQ/FIQ left routed to EL1 (HCR_EL2.IMO/FMO untouched) and DAIF left
       masked -- Stage A has no interrupt source configured yet, unlike
       RPi3's startup.S which unmasks unconditionally. Revisit together
       with the first RPi5 interrupt-driven example (GIC-400 is a real
       ARM GICv2 here, not BCM2837's bespoke controller -- see AGENTS.md). */

    mov     x0, #0
    bl      main

.Lhalt:
    wfe
    b       .Lhalt

/* -- Exception vector table (must be 2KB aligned) ---------------------------
   Every slot just spins, same rationale as examples/common_rpi3/startup.S's
   own table header comment: a spin at a known PC is inspectable over SWD;
   real dispatch is added only once something needs it. */
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
    b       .                   /* 0x200: Current EL SPx, Synchronous */
    .align  7
    b       .                   /* 0x280: Current EL SPx, IRQ */
    .align  7
    b       .                   /* 0x300: Current EL SPx, FIQ */
    .align  7
    b       .                   /* 0x380: Current EL SPx, SError */
    .align  7
    b       .                   /* 0x400: Lower EL AArch64, Synchronous */
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
