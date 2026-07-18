/* Raspberry Pi 3B (BCM2837) bare-metal startup. Never runs via the SD
   card's normal boot path -- see examples/common_rpi3/AGENTS.md and
   jtag_stub.S's header comment: the GPU firmware boots jtag_stub.S's
   spin loop instead, and this file's linked image is injected into RAM
   over JTAG (OpenOCD `load_image` + PC/SP register pokes + `resume`)
   after that stub is halted. No IRQ plumbing yet (unlike
   examples/common_qemu/startup.S) -- nothing in examples/common_rpi3/
   uses interrupts yet; add real dispatch when a real example here needs
   it, not speculatively. The exception VECTOR TABLE below exists anyway
   (every entry just spins) -- see its own comment for why that part is
   not speculative. */
    .section .text.boot
    .global _start
_start:
    /* Only core 0 runs main() -- cores 1-3 must not also call it
       concurrently (duplicate UART output, racing on shared HAL state).
       MPIDR_EL1[1:0] is this SoC's core number. */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbz     x0, .Lcore0
.Lpark:
    wfe
    b       .Lpark

.Lcore0:
    /* This image is injected via JTAG onto a core the GPU firmware/ARM
       Trusted Firmware already brought up -- unlike a genuine hardware
       reset, PC/SP are the only registers OpenOCD's load sequence pokes
       (see scripts/rpi3_jtag_load.sh), so every OTHER system register
       retains whatever the previous occupant left it as (firmware's own
       boot-time value, or the previous test run's value, since repeated
       injections in one power cycle reuse the same live core -- see
       examples/common_rpi3/AGENTS.md's MMU-based safety-check
       reasoning). Clear SCTLR_EL2.A (bit 1, alignment-fault checking)
       unconditionally on every run so unaligned accesses (e.g.
       examples/packed's whole point, or examples/inet_checksum/
       examples/ip_parse's RFC1071 16-bit-at-a-time buffer walks) behave
       the same regardless of what ran before. */
    mrs     x0, sctlr_el2
    bic     x0, x0, #(1 << 1)
    msr     sctlr_el2, x0
    isb

    /* Install the exception vector table before anything else can
       possibly fault -- see its own comment below for why this exists. */
    adrp    x0, exception_vectors
    add     x0, x0, :lo12:exception_vectors
    msr     vbar_el2, x0
    isb

    adrp    x0, stack_top
    add     x0, x0, :lo12:stack_top
    mov     sp, x0

    /* Zero-initialise BSS (identical technique to examples/common_qemu/
       startup.S). */
    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
    cmp     x0, x1
    b.ge    .Lbss_done
.Lbss_loop:
    str     xzr, [x0], #8
    cmp     x0, x1
    b.lt    .Lbss_loop
.Lbss_done:

    /* MMU setup (examples/common_rpi3/mmu.S) MUST run AFTER BSS clear,
       not before: mmu_init's page tables live in .bss (l1_table/
       l2_table), so the ordinary BSS-clear loop above is what zeroes
       them to a known "no entries valid" state before mmu_init
       populates the ones it actually uses -- reversing this order would
       zero out the live page tables mmu_init just built, out from under
       the MMU it just enabled. See mmu.S's header comment for why this
       step exists at all (unaligned-access faults from LLVM's own
       store-merging optimization, not from anything the .tkb source
       does wrong). */
    bl      mmu_init

    bl      main

    /* Real hardware, no semihosting exit available (unlike QEMU) and
       nothing to return to (unlike a flashed STM32 image, there is no
       enclosing firmware here either, since JTAG replaced the running
       core context directly) -- just park. */
.Lhalt:
    wfe
    b       .Lhalt

/* -- Exception vector table (must be 2KB aligned) ------------------------------
   Found the hard way (examples/packed hanging with PC left holding raw
   garbage data, not a code address, after JTAG-halting it mid-hang --
   see examples/common_rpi3/AGENTS.md): with VBAR_EL2 left at whatever
   ARM Trusted Firmware set it to, an unrelated fault's exception entry
   itself faults (that firmware-owned vector table is not guaranteed to
   still be mapped/valid once our own code has been running a while, and
   is not ours to depend on regardless), corrupting CPU state badly
   enough that even OpenOCD's halted-PC readout stops being a real code
   address. Every entry here just spins -- this is a safety net for
   controlled, debuggable behavior on ANY fault (a spin at a known PC,
   inspectable over JTAG, beats state corrupted enough that the debugger
   itself can no longer make sense of it), not functional interrupt
   dispatch; add real handling to the entry that matters once a real
   example needs it. */
    .section .text.vectors
    .align  11         /* 2^11 = 2048 byte alignment */
    .global exception_vectors
exception_vectors:
    /* Current EL, SP0 */
    b       .                   /* 0x000: Synchronous */
    .align  7
    b       .                   /* 0x080: IRQ */
    .align  7
    b       .                   /* 0x100: FIQ */
    .align  7
    b       .                   /* 0x180: SError */
    /* Current EL, SPx (EL2H is this group -- confirmed via OpenOCD's
       "current mode: EL2H" halt report) */
    .align  7
    b       .                   /* 0x200: Synchronous */
    .align  7
    b       .                   /* 0x280: IRQ */
    .align  7
    b       .                   /* 0x300: FIQ */
    .align  7
    b       .                   /* 0x380: SError */
    /* Lower EL (AArch64) */
    .align  7
    b       .                   /* 0x400: Synchronous */
    .align  7
    b       .                   /* 0x480: IRQ */
    .align  7
    b       .                   /* 0x500: FIQ */
    .align  7
    b       .                   /* 0x580: SError */
    /* Lower EL (AArch32) */
    .align  7
    b       .                   /* 0x600: Synchronous */
    .align  7
    b       .                   /* 0x680: IRQ */
    .align  7
    b       .                   /* 0x700: FIQ */
    .align  7
    b       .                   /* 0x780: SError */
