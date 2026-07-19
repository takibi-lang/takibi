    .text
    .align 2

/* -- Per-range D-cache maintenance stubs ----------------------------------
   `dc`/cache-maintenance instructions cannot be issued directly from
   takibi, so these are thin assembly wrappers, same convention as every
   other extern fn stub in this directory (see timer_asm.S's own header
   comment). Needed because this board's compiler-builtin DMA barriers
   (dma_prepare_tx/dma_prepare_rx/dma_finish_rx) lower to a bare `dsb sy`
   on AArch64 targets -- no actual cache clean/invalidate instruction is
   emitted (confirmed by reading lib/llvm_gen.ml; this was harmless on
   QEMU, which has no cache model at all, but is a real gap now that this
   board genuinely runs with D-cache enabled, see examples/common_rpi3/
   mmu.S's own header comment on why caches are on). Anything that hands
   a buffer to a bus master that does not go through this core's cache
   (the VideoCore mailbox, and later this directory's USB/DWC2 DMA
   descriptor rings) must call these explicitly around the hand-off,
   the same way examples/common_rpi3/startup.S's dcache_invalidate_all
   already does for the WHOLE cache at boot -- these are the
   address-range-bounded, VA-based counterpart of that same idea (`dc
   cvac`/`dc ivac` by VA, not the set/way sweep dcache_invalidate_all
   uses, since here the exact range is known and set/way would be
   needlessly invasive).

   Line size comes from CTR_EL0.DminLine (bits 19:16, log2 of the line
   size in WORDS) rather than being hardcoded -- the standard ARMv8 way
   to size a VA-based cache-maintenance loop; unlike
   dcache_invalidate_all's CLIDR_EL1/CCSIDR_EL1 walk (which needs the
   exact set/way geometry per cache level), a VA op only needs to know
   the stride to increment by, and CTR_EL0 gives that directly without
   selecting a cache level first. Both start addresses are rounded DOWN
   to a line boundary and the end address is walked up to (not rounded),
   matching the usual "clean/invalidate every line the range touches"
   semantics -- a caller passing an already-aligned buffer (as every
   caller here does, since DMA buffers are always at least
   line-aligned) never notices the rounding. */

    .global dcache_clean_range
    .type   dcache_clean_range, %function
dcache_clean_range:            /* fn dcache_clean_range(addr: usize, len: usize) */
    mrs     x2, ctr_el0
    ubfx    x2, x2, #16, #4    /* x2 = DminLine */
    mov     x3, #4
    lsl     x3, x3, x2         /* x3 = line size in bytes */
    add     x1, x0, x1         /* x1 = end address */
    sub     x4, x3, #1
    bic     x0, x0, x4         /* x0 = line-aligned start */
.Lclean_loop:
    dc      cvac, x0           /* clean by VA to point of coherency:
                                   CPU-written data becomes visible to a
                                   bus master, cache line stays valid */
    add     x0, x0, x3
    cmp     x0, x1
    b.lo    .Lclean_loop
    dsb     ish
    ret

    .global dcache_invalidate_range
    .type   dcache_invalidate_range, %function
dcache_invalidate_range:       /* fn dcache_invalidate_range(addr: usize, len: usize) */
    mrs     x2, ctr_el0
    ubfx    x2, x2, #16, #4
    mov     x3, #4
    lsl     x3, x3, x2
    add     x1, x0, x1
    sub     x4, x3, #1
    bic     x0, x0, x4
.Linval_loop:
    dc      ivac, x0           /* invalidate by VA to point of coherency:
                                   discard any stale CPU-cached copy so
                                   the next load re-fetches what a bus
                                   master just wrote -- NOT clean first,
                                   deliberately: this is only ever called
                                   on a range the CPU is done writing to
                                   and about to read fresh device output
                                   from, so there is nothing worth
                                   preserving in the cache here */
    add     x0, x0, x3
    cmp     x0, x1
    b.lo    .Linval_loop
    dsb     ish
    isb
    ret
