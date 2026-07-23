/* EL1 -> EL2 hvc call boundary (GitHub issue #154): lets EL1 explicitly
   call into EL2 for privileged operations EL1 cannot perform itself
   (TTBR0_EL2 manipulation -- unmapping a page, deactivating an address
   space -- the same gap that motivated this mechanism: exit(), which
   runs at EL1, currently just abandons those EL2-level resources since
   nothing routes a request from EL1 back up to EL2). Mirrors
   el0_asm.S's own EL0->EL1 SVC boundary one level up, but simpler:
   unlike a syscall, there is no "terminate, do not resume" outcome here
   -- hvc always returns to EL1 at the next instruction after handling,
   like an ordinary privileged function call.

   This first landing proves only the trap mechanism itself (EL1 issues
   hvc, EL2 receives it via a real vector handler, resumes EL1
   correctly) -- see issue #154 for the real resource-teardown logic
   this is meant to eventually carry, deliberately not attempted yet in
   this pass. */
    .section .text

/* usize rpi3_hvc_call(usize arg) -- issued FROM EL1. Ordinary AAPCS64
   call/return; unlike rpi3_el0_enter/rpi3_el1_enter, this DOES return to
   its caller (hvc's whole point is a privileged call-and-return, not a
   one-way transition). */
    .global rpi3_hvc_call
rpi3_hvc_call:
    hvc     #0
    ret

/* -- Default (weak) EL1 hvc dispatch policy ---------------------------------
   Every request is unhandled (returns 0) until an example provides a
   strong Takibi-compiled override with the same name, same weak/strong
   pattern as el0_asm.S's el0_svc_dispatch. */
    .weak   hvc_dispatch
hvc_dispatch:
    mov     x0, #0
    ret

/* -- Real EL1->EL2 hvc entry -------------------------------------------
   Reached via startup.S's exception_vectors' Lower-EL-AArch64-
   Synchronous slot. Full 272-byte frame, same shape as
   rpi3_sync_exception_entry/rpi3_irq_entry/el0_asm.S's own el0_sync_entry
   -- hvc always resumes EL1 (no terminate path), so every register must
   survive untouched except x0 (the call's own return value). */
    .global el1_hvc_entry
    .type   el1_hvc_entry, %function
el1_hvc_entry:
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
