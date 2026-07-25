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
   barriers.

   Both forms below ALSO issue `tlbi vaae1is` (GitHub issue #158's real
   fork()+execve()): `vae2is` covers only the EL2 translation regime -- the
   one EL2 code itself executes through -- while a real EL0 process runs in
   the SEPARATE EL1&0 regime (TTBR0_EL1), whose TLB `vae2is` never touches.
   This was invisible until issue #158 because every earlier user of these
   wrappers changed mappings only BEFORE entering EL0 (or from pure-EL2
   demos with no EL0 at all), so no EL0-visible translation ever needed
   invalidating while a process was live. A real COW write fault is the
   first case that does: the handler rewrites the faulting page's L3
   descriptor read-write and returns to retry the SAME instruction, which
   loops forever re-faulting on the stale read-only EL1&0 entry unless that
   regime is invalidated too (confirmed on real hardware -- the identical
   Permission-fault ESR repeated at the identical FAR after the descriptor
   had already been corrected). `vaae1is` (all-ASID form) rather than
   `vae1is` because every dynamic-window descriptor this kernel writes
   leaves nG clear, i.e. GLOBAL, and global entries are matched regardless
   of ASID -- see mmu_address_space_activate's own matching comment in
   mmu.S. */

    .global tlb_invalidate_va
    .type   tlb_invalidate_va, %function
tlb_invalidate_va:       /* fn tlb_invalidate_va(va: usize) */
    dsb     ishst
    lsr     x0, x0, #12
    tlbi    vae2is, x0
    adrp    x2, rpi3_el1_regime_active
    add     x2, x2, :lo12:rpi3_el1_regime_active
    ldr     x3, [x2]
    cbz     x3, .Ltlb_va_done
    tlbi    vaae1is, x0
.Ltlb_va_done:
    dsb     ish
    isb
    ret

/* ASID-aware form for the real multi-address-space path.  TLBI VAE2IS takes
   ASID in bits[63:48] and VA>>12 in bits[43:0] of its register operand;
   TLBI VAAE1IS takes VA>>12 alone (it deliberately matches every ASID, see
   the header comment above), so the shifted VA is computed into its own
   register first and both instructions read what they each need. */
    .global tlb_invalidate_asid_va
    .type   tlb_invalidate_asid_va, %function
tlb_invalidate_asid_va:  /* fn(asid: usize, va: usize) */
    dsb     ishst
    lsr     x1, x1, #12
    lsl     x0, x0, #48
    orr     x0, x0, x1
    tlbi    vae2is, x0
    adrp    x2, rpi3_el1_regime_active
    add     x2, x2, :lo12:rpi3_el1_regime_active
    ldr     x3, [x2]
    cbz     x3, .Ltlb_asid_va_done
    tlbi    vaae1is, x1
.Ltlb_asid_va_done:
    dsb     ish
    isb
    ret

/* A TTBR0_EL2 context switch changes the translation regime behind every
   virtual address.  Cortex-A53 does not invalidate prior EL2 translations on
   an MSR to TTBR0_EL2, so the switch API uses this whole-EL2 broadcast form
   before it hands the new ActiveAddressSpace token to takibi code. */
    .global tlb_invalidate_all_el2
    .type   tlb_invalidate_all_el2, %function
tlb_invalidate_all_el2:  /* fn tlb_invalidate_all_el2() */
    dsb     ishst
    tlbi    alle2is
    dsb     ish
    isb
    ret

/* GitHub issue #158's real execve(): I-cache/D-cache coherency for freshly
   loaded code. Cortex-A53's L1 I-cache and D-cache are separate arrays --
   el0_load_elf_into's own segment-copy loop (examples/vm_page_map/
   vm_page_map_core.tkb's own DYN_VA_BASE window is Normal Write-Back
   Cacheable, see map_page's own comment) writes new instruction bytes
   through the D-cache side only. Two SEPARATE gaps, both required,
   confirmed the hard way (a first version of this function only did the
   I-cache half below and the crash it was meant to fix persisted
   unchanged on real hardware): (1) a write-back D-cache does not push a
   freshly written line out to the point of unification just because it
   was written -- `dc cvau` per line does that -- so without it, even an
   invalidated I-cache would still re-fetch the OLD bytes from memory;
   (2) the (by-then-correct) I-cache still needs `ic ivau` per line to
   discard whatever it had already cached for that VA. This was never
   needed before issue #158: every earlier EL0 image (el0_smoke,
   el0_elf_load, el0_shell's own boot-time busybox load) was written to
   memory the CPU had never fetched instructions from before and then run
   exactly once from a cold cache -- execve() is the first scenario that
   loads a SECOND process image (a real fork()'s child) while the CPU has
   been running continuously with warm caches, the first time this gap
   was ever exercised.

   Per-line (not whole-cache): Cortex-A53's D-cache/I-cache minimum line
   size is 64 bytes (CTR_EL0 DminLine/IminLine = 4, i.e. 4 << 4) -- fixed
   here rather than read from CTR_EL0 at runtime, matching this whole
   target's existing `--cpu cortex-a53`-specific pragmatism (mmu.S's own
   fixed two-level page table layout, tlb_asm.S's own fixed VAE2IS shift
   amounts, etc. -- none of this reads back what the hardware actually is
   at runtime either). x2 walks the range one line at a time; x1 is the
   exclusive end address, rounded the same way both loops below round
   their own start down to a line boundary first so a range that starts
   or ends mid-line is still fully covered. */
    .global rpi3_code_range_sync
    .type   rpi3_code_range_sync, %function
rpi3_code_range_sync:  /* fn rpi3_code_range_sync(va: usize, len: usize) */
    add     x1, x0, x1
    bic     x2, x0, #63
.Ldcache_clean_loop:
    dc      cvau, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    .Ldcache_clean_loop
    dsb     ish

    bic     x2, x0, #63
.Licache_invalidate_loop:
    ic      ivau, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    .Licache_invalidate_loop
    dsb     ish
    isb
    ret
