    .text
    .align 2

/* -- Semaphore (atomic implementation using ldaxr / stlxr) --------------------------

   sem_wait(s: *int)
     Spins until the counter is positive, then atomically decrements it.
     Reads with ldaxr (load-exclusive + acquire barrier),
     writes back with stxr (store-exclusive).
     When counter == 0, clears the exclusive monitor with clrex and retries.
     Also retries from the top on store conflict (another core broke the exclusive).  */

    .global sem_wait
    .type   sem_wait, %function
sem_wait:                   /* fn sem_wait(s: *int) */
.Lw_retry:
    ldaxr   w1, [x0]        /* load-exclusive (+ acquire) */
    cbz     w1, .Lw_zero    /* counter == 0: wait */
    sub     w2, w1, #1
    stxr    w3, w2, [x0]    /* store-exclusive; w3 == 0 means success */
    cbnz    w3, .Lw_retry   /* conflict -> retry from the top */
    ret
.Lw_zero:
    clrex                   /* clear exclusive monitor */
    b       .Lw_retry

/*   sem_post(s: *int)
     Atomically increments the counter.
     Writes back with stlxr (store-exclusive + release barrier).  */

    .global sem_post
    .type   sem_post, %function
sem_post:                   /* fn sem_post(s: *int) */
.Lp_retry:
    ldxr    w1, [x0]        /* load-exclusive */
    add     w2, w1, #1
    stlxr   w3, w2, [x0]   /* store-exclusive (+ release) */
    cbnz    w3, .Lp_retry   /* conflict -> retry */
    ret
