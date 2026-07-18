/* Raspberry Pi 3B (BCM2837) bare-metal startup. Never runs via the SD
   card's normal boot path -- see examples/common_rpi3/AGENTS.md and
   jtag_stub.S's header comment: the GPU firmware boots jtag_stub.S's
   spin loop instead, and this file's linked image is injected into RAM
   over JTAG (OpenOCD `load_image` + PC/SP register pokes + `resume`)
   after that stub is halted. IRQ dispatch (rpi3_irq_entry below) vectors
   straight to examples/common_rpi3/intc.tkb's rpi3_irq_dispatch(), which
   checks BCM2837's own 2-level interrupt controller and calls
   examples/common_rpi3/uart.tkb's uart_irq_handler() directly -- NOT the
   examples/common_qemu/startup.S pattern of a generic `irq_dispatch`
   symbol examples/echo/echo.tkb and examples/irq/irq.tkb define
   themselves (that stays dead code here, same as on STM32; see
   intc.tkb's header comment for why). No task-switching support yet
   (unlike QEMU's irq_entry, which can resume a DIFFERENT frame_sp) --
   add it only once a real preemptive-scheduler example needs it here,
   not speculatively. */
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

    /* Route physical IRQ/FIQ to EL2 (HCR_EL2.IMO bit 4 / FMO bit 3 --
       two adjacent bits, so #0x18 is a single valid AArch64 bitmask
       immediate). Without IMO, the architecture routes physical IRQs to
       EL1 -- and an interrupt targeting a LOWER EL than the one
       currently executing is implicitly masked no matter what PSTATE.I
       says, so code that stays at EL2 (as everything here does) simply
       never takes one. Found the hard way on examples/echo: UART0_MIS
       showed RXMIS asserted, the VC controller's pending_2 showed
       UART0's bit, GPU routing pointed at core 0, DAIF.I was clear --
       every observable layer said "pending" and the core still never
       vectored, the exact signature of this rule. Inherited-state
       reasoning as usual (see below): the GPU firmware leaves IMO=0
       because Linux takes its interrupts at EL1 and EL2 is just a
       pass-through trampoline for it, so we must set this ourselves,
       unconditionally, every run. */
    mrs     x0, hcr_el2
    orr     x0, x0, #0x18
    msr     hcr_el2, x0
    isb

    adrp    x0, stack_top
    add     x0, x0, :lo12:stack_top
    mov     sp, x0

    /* Zero-initialise BSS -- and, unlike examples/common_qemu/startup.S,
       keep going through the .stack region too (link.ld places it
       directly after .bss, so extending the same loop's end symbol from
       __bss_end to stack_top covers both). QEMU's cold boot hands every
       example all-zero RAM, and STM32's harness behaves close enough,
       but JTAG re-injection here reuses whatever RAM the PREVIOUS
       example left behind -- caught by examples/packed, whose .expected
       fixture prints a struct's padding byte as 0x00: the value of a
       padding byte is genuinely unspecified, and on this target it sat
       at a stack address a previous run's deeper call/IRQ frames had
       scribbled on, failing the diff nondeterministically (observed as
       0x07/0x17/0x9c/0xa2 across runs). Zeroing the stack region on
       every entry restores the same deterministic all-zero initial
       state every other target's run effectively starts from. Safe at
       this point: SP was just set to stack_top and nothing has been
       pushed yet, so the whole [stack base, stack_top) range is dead. */
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

    /* Quiesce inherited peripheral-interrupt state BEFORE unmasking
       PSTATE.I below. QEMU's startup.S can DAIFClr first thing because
       a fresh QEMU boot has every interrupt source at its reset
       (masked) state; here, PERIPHERAL registers survive JTAG
       re-injection exactly like system registers do, so a previous
       examples/echo run leaves UART0_IMSC's RX bit set, the VC
       controller's UART0 line enabled, and possibly an unread byte
       sitting in the UART -- a still-asserted, level-triggered IRQ.
       Found the hard way, the very first run after HCR_EL2.IMO (above)
       started actually delivering IRQs at EL2: every example in the
       suite, including the 33 that never touch interrupts, died with no
       output at all -- the leftover pending IRQ fired the instant DAIF.I
       was cleared, and for a non-interrupt example the weak no-op
       rpi3_irq_dispatch below "handles" a level interrupt by not
       acknowledging it, which re-fires it forever (an interrupt storm
       that looks like a silent hang from the outside). Masking the UART
       at its source AND disabling every VC controller line returns the
       interrupt fabric to its cold-boot state; examples that want the
       interrupt re-enable it themselves (intc.tkb's
       irq_uart_rx_setup/irq_uart_rx_unmask). The three VC disable
       registers sit at consecutive offsets (0x3F00B21C/0x220/0x224 =
       Disable_IRQs_1 / Disable_IRQs_2 / Disable_Basic_IRQs, per the
       Linux kernel's irq-bcm2835.c reg_disable table); writing
       all-ones to each disables every line in that bank. Placed AFTER
       mmu_init so these MMIO addresses go through the same Device
       mappings normal driver code uses. */
    movz    x1, #0x1038
    movk    x1, #0x3F20, lsl #16
    str     wzr, [x1]                 /* UART0_IMSC = 0: mask at the source */
    movz    x1, #0xB21C
    movk    x1, #0x3F00, lsl #16
    mov     w2, #-1
    str     w2, [x1]                  /* Disable_IRQs_1 */
    str     w2, [x1, #4]              /* Disable_IRQs_2 (incl. UART0, bit 25) */
    str     w2, [x1, #8]              /* Disable_Basic_IRQs */

    /* Enable IRQ and FIQ (clear DAIF.I and DAIF.F) unconditionally --
       safe only now: SP is valid, BSS/stack are zeroed, the MMU maps
       the device registers rpi3_irq_dispatch would touch, and the
       quiescing above guarantees no stale source is still asserting.
       For the examples that never call irq_uart_rx_setup()/
       irq_uart_rx_unmask() this is inert, same reasoning as
       examples/common_qemu/startup.S. */
    msr     DAIFClr, #0x3
    isb

    bl      main

    /* Real hardware, no semihosting exit available (unlike QEMU) and
       nothing to return to (unlike a flashed STM32 image, there is no
       enclosing firmware here either, since JTAG replaced the running
       core context directly) -- just park. */
.Lhalt:
    wfe
    b       .Lhalt

/* -- Default (no-op) rpi3_irq_dispatch ----------------------------------------
   startup.S is shared by every RPi3 example (the plain-compute ones
   have no interrupt controller set up at all), but rpi3_irq_entry below
   unconditionally calls rpi3_irq_dispatch -- same fix as
   examples/common_qemu/startup.S's own weak irq_dispatch default:
   examples/common_rpi3/intc.tkb's real (strong) definition overrides
   this for examples/echo/examples/irq; every other example links
   against this no-op instead, so the DAIFClr'd-but-nothing-enabled IRQ
   line an unrelated example never unmasks has a harmless place to land
   even if it somehow fired (it never does, since nothing unmasks it). */
    .weak   rpi3_irq_dispatch
rpi3_irq_dispatch:
    ret

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
    b       rpi3_irq_entry      /* 0x280: IRQ  <- normally arrives here */
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

/* -- IRQ entry: save all general-purpose registers, dispatch, restore --------
   Same 272-byte frame layout as examples/common_qemu/startup.S's
   irq_entry (x0-x30 + ELR_EL2/SPSR_EL2, in that order) for the same
   reason: an asynchronous interrupt can land with ANY register live in
   the code it interrupted, unlike a normal call boundary where AAPCS64
   callee-saved registers are the only ones a callee must preserve.
   Unlike QEMU's version, this always resumes the SAME frame (no
   task-switching support yet -- see this file's header comment) --
   examples/common_rpi3/intc.tkb's rpi3_irq_dispatch() takes no
   argument and returns nothing, it just runs
   examples/common_rpi3/uart.tkb's uart_irq_handler() if BCM2837's
   interrupt controller says UART0 is why this fired. */
rpi3_irq_entry:
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

    bl      rpi3_irq_dispatch

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
