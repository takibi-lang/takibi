    .syntax unified
    .thumb
    .align 2

/* -- Semaphore (ARMv7E-M ldrex/strex, Cortex-M7's equivalent of AArch64's
   ldaxr/stxr/ldxr/stlxr) --------------------------------------------------

   Cortex-M has no acquire/release-encoded exclusive-access instructions
   (ldaxr/stlxr) -- ARMv7-M uses plain ldrex/strex plus an explicit dmb
   (data memory barrier), placed after the successful acquire and before
   the release store, per ARM's Cortex-M synchronization-primitives
   guidance. Same calling convention as examples/common/sem_asm.S: r0 =
   pointer to the i32 counter, same retry-loop shape.

   sem_wait(s: *int): spins until the counter is positive, decrements it,
   then a dmb before returning (so nothing after the call can be reordered
   ahead of the acquire). */
    .thumb_func
    .global sem_wait
sem_wait:
.Lw_retry:
    ldrex   r1, [r0]
    cbz     r1, .Lw_zero
    subs    r2, r1, #1
    strex   r3, r2, [r0]
    cmp     r3, #0
    bne     .Lw_retry
    dmb
    bx      lr
.Lw_zero:
    clrex
    b       .Lw_retry

/* sem_post(s: *int): a dmb before the release store (so nothing before the
   call can be reordered after the release), then atomically increments. */
    .thumb_func
    .global sem_post
sem_post:
    dmb
.Lp_retry:
    ldrex   r1, [r0]
    adds    r2, r1, #1
    strex   r3, r2, [r0]
    cmp     r3, #0
    bne     .Lp_retry
    bx      lr
