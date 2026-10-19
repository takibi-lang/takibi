/* SPDX-License-Identifier: MIT
 *
 * CTR_EL0 read for GitHub issue #759's boot-time cache-geometry check
 * (kernel_cache_geometry_require in kernel/init/boot_prologue.tkb is the
 * only caller).
 *
 * Assembly rather than .tkb because this kernel's mrs/msr support is a
 * CLOSED set of intrinsics (lib/type_inf.ml, lib/llvm_gen.ml) and none of
 * them names CTR_EL0; the maintainer chose on 2026-10-19 not to grow that
 * set for this one boot-time read (see kernel/arch/arm64/kernel/pmu.S for
 * the same precedent). The one instruction below has no logic of its own:
 * decoding the fields and deciding whether to halt is in
 * kernel/arch/arm64/kernel/cache_geometry.tkb, where the type system and
 * linux_user/cache_geometry can see it.
 */

    .section .text, "ax"

/* cache_geometry_read_ctr_el0() -> usize
 *
 * The raw CTR_EL0 of the calling core. CTR_EL0 is per core, so each core
 * calls this itself. Readable at EL1 unconditionally. */
    .global cache_geometry_read_ctr_el0
    .type cache_geometry_read_ctr_el0, %function
cache_geometry_read_ctr_el0:
    mrs     x0, ctr_el0
    ret
    .size cache_geometry_read_ctr_el0, . - cache_geometry_read_ctr_el0
