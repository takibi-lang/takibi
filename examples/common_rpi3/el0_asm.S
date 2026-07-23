/* EL1 -> EL0 drop and the real SVC entry (GitHub issue #153): proves the
   syscall trap mechanism itself, decoupled from ELF loading -- the EL0
   payload below is a tiny hand-written, independently-assembled
   instruction sequence (not compiled Takibi code), copied at runtime into
   a freshly mapped EL0-executable page (see
   examples/vm_page_map/vm_page_map_core.tkb's map_page_el0_exec). Keeping
   it hand-written and separate from Takibi codegen means this milestone
   cannot accidentally depend on any EL1-only assumption Takibi's own
   compiled code might carry.

   The payload issues two real AArch64 Linux syscall numbers in sequence
   (write=64, then exit=93) via `svc #0`, proving both the trap-and-resume
   path (write) and the trap-and-terminate path (exit) actually work on
   real hardware, not just a single one-shot trap. */
    .section .rodata
    .align  4
el0_payload_start:
    movz    x8, #64            /* __NR_write */
    movz    x0, #99            /* arbitrary marker value, arg0 */
    svc     #0
    movz    x8, #93            /* __NR_exit */
    svc     #0
.Lel0_payload_hang:
    b       .Lel0_payload_hang /* unreachable if exit is handled correctly */
el0_payload_end:

    .section .text

/* usize el0_payload_addr(void) -- the kernel-image address of the payload
   above (read-only, EL1-only mapped as part of the ordinary identity map;
   the caller copies these bytes into a separately, EL0-accessibly mapped
   page before ever letting EL0 execute). */
    .global el0_payload_addr
el0_payload_addr:
    adrp    x0, el0_payload_start
    add     x0, x0, :lo12:el0_payload_start
    ret

/* usize el0_payload_len(void) */
    .global el0_payload_len
el0_payload_len:
    adrp    x0, el0_payload_start
    add     x0, x0, :lo12:el0_payload_start
    adrp    x1, el0_payload_end
    add     x1, x1, :lo12:el0_payload_end
    sub     x0, x1, x0
    ret

/* void rpi3_el0_enter(usize el0_pc, usize el0_sp) -- never returns to its
   caller (same "one-way" shape as rpi3_el1_enter; only a subsequent SVC
   trap back to EL1, handled by el0_sync_entry below, runs Takibi code
   again). x1 (el0_sp) is only installed into SP_EL0, never dereferenced
   by this milestone's hand-written payload (it does no memory access at
   all) -- a real loaded process will need a genuinely mapped, EL0-
   accessible stack page, deferred until the ELF-loading milestone. */
    .global rpi3_el0_enter
rpi3_el0_enter:
    msr     sp_el0, x1

    /* SPSR_EL1: target EL0t (M[3:0] = 0b0000 -- EL0 has no SPx variant,
       always SP_EL0), DAIF all masked. Unlike the EL2->EL1 drop, no
       HCR_EL2.RW-style register-width pitfall applies here: EL0's
       execution state always matches EL1's own (there is no separate
       per-EL0 AArch32/64 control bit in the EL1&0 regime; HCR_EL2.RW,
       already set by rpi3_el1_enter, governs both). */
    movz    x2, #0x3c0
    msr     spsr_el1, x2
    msr     elr_el1, x0
    eret

/* -- Default (weak) EL0 syscall dispatch policy -----------------------------
   Every syscall number is unhandled until an example provides a strong
   Takibi-compiled override with the same name (same weak/strong pattern
   as startup.S's rpi3_sync_exception_dispatch). Return value convention,
   shared with el0_sync_entry below: 0 = unhandled (fail-stop), 1 =
   terminate (do not resume EL0), any other value MUST equal the passed-in
   `elr` argument (x3) to mean "resume EL0 at that address" -- anything
   else is treated as unhandled too. */
    .weak   el0_svc_dispatch
el0_svc_dispatch:
    mov     x0, #0
    ret

/* -- Real EL0 synchronous exception entry -----------------------------------
   Reached via el1_vectors' Lower-EL-AArch64-Synchronous slot (el1_asm.S).
   Same complete 272-byte register frame shape as rpi3_sync_exception_entry/
   rpi3_irq_entry, since a real syscall's arguments (x0-x5) and every other
   EL0 register must survive an eventual resume unless the process
   terminates. */
    .global el0_sync_entry
    .type   el0_sync_entry, %function
el0_sync_entry:
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
    mrs     x3, elr_el1
    mrs     x4, spsr_el1
    stp     x3, x4, [sp, #256]

    /* el0_svc_dispatch(esr, syscall_num, arg0, elr) -- x3 (elr) already
       holds the right value from the mrs above and is untouched by the
       loads below. */
    mrs     x0, esr_el1
    ldr     x1, [sp, #64]       /* saved x8: syscall number */
    ldr     x2, [sp, #0]        /* saved x0: syscall arg0 */
    bl      el0_svc_dispatch

    ldr     x1, [sp, #256]      /* saved elr */
    cmp     x0, #0
    b.eq    rpi3_exception_unhandled
    cmp     x0, #1
    b.eq    .Lel0_terminate
    cmp     x0, x1
    b.ne    rpi3_exception_unhandled

    /* Resume EL0 at the same elr (the instruction right after `svc`,
       per architecture -- ELR_EL1 was never modified). */
    ldp     x0, x1, [sp, #256]
    msr     elr_el1, x0
    msr     spsr_el1, x1
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

.Lel0_terminate:
    /* No process/task abstraction exists yet to tear down -- this
       milestone's whole point is proving the trap mechanism. Park; a real
       exit() will need real process cleanup once one exists. */
.Lel0_park:
    wfe
    b       .Lel0_park
