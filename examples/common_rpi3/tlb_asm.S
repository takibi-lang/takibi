    .text
    .align 2

/* -- TLB invalidation-by-VA stub ------------------------------------------
   `tlbi` is a system instruction and cannot be issued directly from
   takibi (same reason examples/common_rpi3/timer_asm.S wraps mrs/msr),
   so examples/vm_page_map calls these instruction-sequence wrappers
   instead. Used only after map_page/unmap_page write or clear an L3 page
   descriptor in the selected address space (see examples/common_rpi3/mmu.S's
   header comment for the two-root layout) -- a PTE write alone does not make a mapping
   (or its absence) visible to translations already cached in the TLB;
   this sequence is what makes it so.

   dsb ishst (Inner Shareable, Store) drains the PTE write itself before
   the TLB maintenance instruction runs -- required so `tlbi` cannot race
   a store to the very translation table entry it is about to invalidate.
   `tlbi vae2is, x0` invalidates the cached translation for one VA at EL2
   on every PE in the Inner-Shareable domain.  The original Stage 2
   single-core demo used local `vae2`; smp_page_transfer requires the
   broadcast form because the L3 table and VA are shared across cores.
   TLBI VAE2IS's VA operand is bits[43:0] of
   the input address shifted right 12 (page-aligned, top bits ignored by
   the instruction) -- the `lsr x0, x0, #12` below does that shift so the
   .tkb-facing API can pass a plain byte address. The trailing dsb ish +
   isb is architecturally required after any TLB maintenance instruction,
   before the new translation state may be relied upon by any subsequent
   instruction -- this is the exact "TLB invalidation obligation" GitHub
   issue #67 asks the type system to enforce: no takibi code can reach
   MappingOwner (examples/vm_page_map/vm_page_map_core.tkb's usable-
   mapping state) without going through this call and its trailing
   barriers. */

    .global tlb_invalidate_va
    .type   tlb_invalidate_va, %function
tlb_invalidate_va:       /* fn tlb_invalidate_va(va: usize) */
    dsb     ishst
    lsr     x0, x0, #12
    tlbi    vae2is, x0
    dsb     ish
    isb
    ret

/* ASID-aware form for the real multi-address-space path.  TLBI VAE2IS takes
   ASID in bits[63:48] and VA>>12 in bits[43:0] of its register operand. */
    .global tlb_invalidate_asid_va
    .type   tlb_invalidate_asid_va, %function
tlb_invalidate_asid_va:  /* fn(asid: usize, va: usize) */
    dsb     ishst
    lsl     x0, x0, #48
    lsr     x1, x1, #12
    orr     x0, x0, x1
    tlbi    vae2is, x0
    dsb     ish
    isb
    ret
