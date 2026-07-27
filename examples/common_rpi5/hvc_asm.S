/* EL1 -> EL2 hvc call boundary for RPi5 -- port of examples/common_rpi3/
   hvc_asm.S's own proven mechanism (GitHub issue #154 on RPi3). Builds
   directly on examples/common_rpi5/el1_asm.S's proven EL2->EL1 drop
   (rpi5_el1_enter): lets EL1 explicitly call into EL2 for privileged
   operations, the same "ordinary privileged call-and-return" shape as
   RPi3's own version -- hvc always resumes EL1 at the next instruction
   after handling, unlike a one-way transition. This first landing
   proves only the trap mechanism itself (EL1 issues hvc, EL2 receives
   it via a real vector handler, resumes EL1 correctly); no real
   resource-teardown logic is attempted, matching RPi3's own first pass.

   Naming: rpi5_hvc_call (not a bare "hvc_call") mirrors rpi5_el1_enter's
   own board-prefixed naming, since it is called directly from a .tkb
   file the same way. el1_hvc_entry/hvc_dispatch are NOT board-prefixed,
   matching RPi3's own choice for these two (no cross-target naming
   collision risk: these live in separate per-target object files that
   are never linked together). */
    .section .text

/* usize rpi5_hvc_call(usize arg) -- issued FROM EL1. Ordinary AAPCS64
   call/return; unlike rpi5_el1_enter, this DOES return to its caller. */
    .global rpi5_hvc_call
    .global rpi3_hvc_call
rpi5_hvc_call:
rpi3_hvc_call:
    hvc     #0
    ret

/* -- Default (weak) EL1 hvc dispatch policy ---------------------------------
   Every request is unhandled (returns 0) until an example provides a
   strong Takibi-compiled override with the same name. */
    .weak   hvc_dispatch
hvc_dispatch:
    mov     x0, #0
    ret

/* -- Real EL1->EL2 hvc entry -------------------------------------------
   Reached via examples/common_rpi5/startup.S's exception_vectors' own
   Lower-EL-AArch64-Synchronous slot (0x400) -- EL2's OWN vector table,
   not EL1's, since hvc traps UP from EL1 to EL2. Full 272-byte frame,
   same shape as startup.S's own rpi5_irq_entry -- hvc always resumes
   EL1 (no terminate path), so every register must survive untouched
   except x0 (the call's own return value). */
    .global el1_hvc_entry
    .type   el1_hvc_entry, %function
el1_hvc_entry:
    /* This vector slot receives every synchronous exception from EL1,
       not only HVC.  Accept EC=0x16 (HVC64) and park all other causes in
       the ordinary evidence handler instead of decoding an arbitrary x0
       value as a privileged request. */
    mrs     x1, esr_el2
    lsr     x2, x1, #26
    cmp     x2, #0x16
    b.ne    rpi3_exception_unhandled

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

    ldr     x0, [sp, #0]        /* saved x0: the call's own argument */
    bl      hvc_dispatch
    str     x0, [sp, #0]        /* overwrite saved x0 with the return value */

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
