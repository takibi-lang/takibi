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
   via `svc #0`: write(1, el0_msg, 12), then exit(93). This proves real
   write() semantics end to end -- the kernel must validate this pointer
   (el0_msg lives inside the SAME copied page, addressed PC-relative via
   `adr` so the offset survives the copy unchanged) and the returned byte
   count actually reflects what the kernel read, not just that a trap
   happened -- as well as both the trap-and-resume path (write) and the
   trap-and-terminate path (exit) on real hardware. */
    .section .rodata
    .align  4
el0_payload_start:
    adr     x1, el0_msg
    /* EL0_MSG_LEN below (12) must match el0_msg's own byte length --
       llvm-mc does not accept a `(label - label)` byte-count as a movz
       immediate operand (tried, rejected: "immediate must be an integer
       in range [0, 65535]" even though the difference is a compile-time
       constant), so this is a plain literal instead. */
    movz    x2, #12            /* EL0_MSG_LEN */
    movz    x0, #1             /* fd = 1 (stdout) */
    movz    x8, #64            /* __NR_write */
    svc     #0
    /* x0 now holds write()'s return value (bytes written, kernel-set).
       Confirm it matches the requested length before exiting -- a
       mismatch here would mean el0_svc_dispatch validated/copied the
       wrong thing, not just that SOME trap occurred. */
    movz    x1, #12            /* EL0_MSG_LEN, same caveat as above */
    cmp     x0, x1
    b.ne    .Lel0_payload_hang
    movz    x8, #93            /* __NR_exit */
    svc     #0
.Lel0_payload_hang:
    b       .Lel0_payload_hang /* unreachable if write/exit behave correctly */
    .align  4
el0_msg:
    .ascii  "hi from el0\n"    /* EL0_MSG_LEN (12) bytes -- keep in sync */
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

/* void rpi3_el0_resume_frame(usize frame_ptr) -- never returns to its
   caller, same one-way shape as rpi3_el0_enter above, but restores EVERY
   register (x0-x30, ELR_EL1, SPSR_EL1) from an arbitrary caller-supplied
   272-byte frame instead of only setting PC+SP. GitHub issue #158's real
   fork(): a forked child reuses el0_sync_entry's own existing "resume
   the SAME trap frame" path below (only x0/ELR ever change there,
   exactly what fork() needs for the child -- same registers as the
   parent except x0=0), but the SUSPENDED PARENT's own frame -- saved
   elsewhere in memory at fork() time, since the live trap frame gets
   reused by the child -- is a DIFFERENT, arbitrary frame, not "whatever
   is on the stack right now". Neither existing entry point covers that:
   rpi3_el0_enter only ever sets PC+SP (fine for a fresh process image,
   wrong here -- it would lose the parent's real x1-x30), and
   el0_sync_entry's own resume path only ever resumes the CURRENT frame.
   This is purely additive -- el0_sync_entry's own logic below is
   UNCHANGED -- so examples/el0_smoke and examples/el0_elf_load, which
   never call this, are unaffected.

   Same 272-byte layout as el0_sync_entry's own save area (x0/x1 at +0,
   x2/x3 at +16, ... x30/xzr at +240, ELR_EL1/SPSR_EL1 at +256). x0
   itself (the frame_ptr argument) is loaded dead LAST, since every
   earlier load addresses the frame through it -- overwriting x0 any
   sooner would lose the base address before this function is done
   reading from it. */
    .global rpi3_el0_resume_frame
rpi3_el0_resume_frame:
    ldp     x1, x2, [x0, #256]
    msr     elr_el1, x1
    msr     spsr_el1, x2
    ldp     x2, x3, [x0, #16]
    ldp     x4, x5, [x0, #32]
    ldp     x6, x7, [x0, #48]
    ldp     x8, x9, [x0, #64]
    ldp     x10, x11, [x0, #80]
    ldp     x12, x13, [x0, #96]
    ldp     x14, x15, [x0, #112]
    ldp     x16, x17, [x0, #128]
    ldp     x18, x19, [x0, #144]
    ldp     x20, x21, [x0, #160]
    ldp     x22, x23, [x0, #176]
    ldp     x24, x25, [x0, #192]
    ldp     x26, x27, [x0, #208]
    ldp     x28, x29, [x0, #224]
    ldp     x30, xzr, [x0, #240]
    ldp     x0, x1, [x0, #0]
    eret

/* -- Default (weak) EL0 syscall dispatch policy -----------------------------
   Every syscall number is unhandled until an example provides a strong
   Takibi-compiled override with the same name (same weak/strong pattern
   as startup.S's rpi3_sync_exception_dispatch).

   Signature: el0_svc_dispatch(esr, syscall_num, x0, x1, x2, elr, frame_sp) -> (outcome, retval)
   -- x0/x1/x2 are the EL0 process's OWN saved x0/x1/x2 at trap time (a
   syscall's first three argument registers per the AArch64 Linux ABI;
   only write's fd/buf/len are meaningful yet, but every syscall's
   dispatcher receives the same three so a future read()/other 3-arg
   syscall needs no signature change). `frame_sp` (GitHub issue #158,
   passed in x6) is this trap's own 272-byte saved register frame's base
   address -- see rpi3_el0_resume_frame's own comment above for why a
   real fork() needs it (to copy the parent's full frame out before the
   child reuses it). Purely additive: examples/el0_smoke and examples/
   el0_elf_load's own 6-parameter el0_svc_dispatch overrides simply never
   read x6, which AAPCS64 permits a caller to over-supply harmlessly.

   `outcome` convention, shared with el0_sync_entry below: 0 = unhandled
   (fail-stop), 1 = terminate (do not resume EL0), any other value MUST
   equal the passed-in `elr` argument (x5) to mean "resume EL0 at that
   address" -- anything else is treated as unhandled too. `retval` is
   only consulted on the resume path: it becomes the resumed EL0's own
   x0 (the syscall return value a real caller/libc would check), same
   register Linux itself returns syscall results in. */
    .weak   el0_svc_dispatch
el0_svc_dispatch:
    mov     x0, #0
    mov     x1, #0
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
    mrs     x9, elr_el1
    mrs     x10, spsr_el1
    stp     x9, x10, [sp, #256]

    /* el0_svc_dispatch(esr, syscall_num, x0, x1, x2, elr) -> (outcome, retval).
       x9 (elr, from the mrs above) is copied into x5 last so none of the
       loads below (which reuse x0-x4) can clobber it first. */
    mrs     x0, esr_el1
    ldr     x1, [sp, #64]       /* saved x8: syscall number */
    ldr     x2, [sp, #0]        /* saved x0 */
    ldr     x3, [sp, #8]        /* saved x1 */
    ldr     x4, [sp, #16]       /* saved x2 */
    mov     x5, x9              /* elr */
    mov     x6, sp              /* frame_sp -- this trap's own saved frame */
    bl      el0_svc_dispatch
    mov     x6, x0              /* outcome */
    mov     x7, x1              /* retval */

    ldr     x1, [sp, #256]      /* saved elr */
    cmp     x6, #0
    b.eq    rpi3_exception_unhandled
    cmp     x6, #1
    b.eq    .Lel0_terminate
    cmp     x6, x1
    b.ne    rpi3_exception_unhandled

    /* Resume EL0 at the same elr (the instruction right after `svc`,
       per architecture -- ELR_EL1 was never modified). Overwrite the
       saved x0 slot with the syscall's return value before restoring, so
       EL0 sees it in x0 exactly like a real syscall return. */
    str     x7, [sp, #0]
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
