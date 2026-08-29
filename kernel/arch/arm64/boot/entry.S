/* SPDX-License-Identifier: MIT
 * Thin RPi5 boot shim for issue #177. TF-A hands off at EL2; this file does
 * the system-register work Takibi cannot express and drops exactly once to
 * the monolithic EL1 kernel. It is not an EL2 service layer.
 */

    .section .text.boot, "ax"
    .global _start
    .type _start, %function
_start:
    mov     x19, x0
    mrs     x0, mpidr_el1
    lsr     x0, x0, #8
    and     x0, x0, #3
    cbnz    x0, .Lpark

    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.hs    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:
    adrp    x0, boot_dtb_address
    add     x0, x0, :lo12:boot_dtb_address
    str     x19, [x0]
    adrp    x0, boot_stack_top
    add     x0, x0, :lo12:boot_stack_top
    adr     x1, .Lel1_entry
    bl      el2_drop_to_el1

.Lel1_entry:
    /* GitHub issue #477: this core's byte offset into the per-core stack
     * groups, in TPIDR_EL1, which the generated exception entries add to
     * every stack address they compute.  Zero for the primary: its group
     * IS the base one the linker script's symbols name.
     *
     * The FIRST instruction after the drop, because VBAR_EL1 is already
     * live by then (el2_drop_to_el1 sets it) and a vector that ran before
     * this would compute its stack from a garbage register.  DAIF is
     * masked across the whole window, so only a synchronous fault could
     * reach it, and that is already fatal -- this just keeps it reportable.
     *
     * Linux sets the same register at the same point (init_cpu_task in
     * __primary_switched, after the MMU and before C), except that it
     * stores a per-CPU AREA offset because it has thousands of per-CPU
     * variables to reach.  The only per-core thing a vector here has to
     * find is its stack, so the offset is the whole answer.
     *
     * Neither entry path asks MPIDR which core it is.  It does not have
     * to: PSCI starts exactly one secondary, so this path is core 0 by
     * construction and kernel_secondary_entry is core 1 by construction.
     * That is what keeps the per-platform affinity-field difference
     * (GitHub issue #445) out of the shared logic. */
    msr     tpidr_el1, xzr
    bl      el1_fpsimd_enable
    bl      kernel_mmu_init
    bl      main

.Lpark:
    wfe
    b       .Lpark

    .global boot_dtb_address_read
    .type boot_dtb_address_read, %function
boot_dtb_address_read:
    adrp    x0, boot_dtb_address
    add     x0, x0, :lo12:boot_dtb_address
    ldr     x0, [x0]
    ret

    .section .bss.boot, "aw", %nobits
    .align 3
boot_dtb_address:
    .skip 8

    .section .text.boot, "ax"

/* PSCI enters a successfully started secondary in Non-secure EL2 with x0
 * carrying the caller-supplied context. Unlike the JTAG loader, this path is
 * equally usable when the same image is later loaded from SD/USB/network. */
    .global kernel_secondary_entry
kernel_secondary_entry:
    msr     DAIFSet, #0xf
    mov     x19, x0

    adrp    x0, secondary_stack_top
    add     x0, x0, :lo12:secondary_stack_top
    adr     x1, .Lsecondary_el1
    bl      el2_drop_to_el1

.Lsecondary_el1:
    /* GitHub issue #477: this core's offset into the per-core stack
     * groups.  Computed from the two linker symbols rather than from a
     * stride constant repeated here, so changing the layout moves this
     * with it.  See .Lel1_entry for why neither path reads MPIDR. */
    adrp    x0, secondary_percpu_stack_base
    add     x0, x0, :lo12:secondary_percpu_stack_base
    adrp    x1, percpu_stack_base
    add     x1, x1, :lo12:percpu_stack_base
    sub     x0, x0, x1
    msr     tpidr_el1, x0
    bl      el1_fpsimd_enable
    bl      kernel_mmu_init_secondary
    mov     x0, x19
    /* GitHub issue #445: the core index is cpu_id() in
     * kernel/platform/rpi5/init.tkb now, not an ubfx here. The width and
     * position of the field differ per platform and this file had one of
     * the two copies. */
    bl      kernel_secondary_main
.Lsecondary_park:
    wfe
    b       .Lsecondary_park

/* el2_drop_to_el1(stack_top: x0, el1_entry: x1): the EL2 configuration and
 * drop-to-EL1 sequence shared by _start and kernel_secondary_entry (GitHub
 * issue #224) -- previously duplicated register-for-register between the
 * primary and secondary boot paths, with nothing keeping the two copies in
 * sync. Configures physical counter/timer trapping, EL1/EL0 execution
 * state, the one shared vector table, and the caller's own stack (as both
 * the live EL2 SP and SP_EL1), then erets to el1_entry in EL1h with DAIF
 * masked. Never returns -- the caller's `bl` return address is unused,
 * matching how .Lel1_entry/.Lsecondary_el1 are reached below. */
    .global el2_drop_to_el1
    .type el2_drop_to_el1, %function
el2_drop_to_el1:
    mov     sp, x0

    /* EL1 may use the physical counter/timer without trapping to EL2. */
    mrs     x2, cnthctl_el2
    orr     x2, x2, #3
    msr     cnthctl_el2, x2

    /* EL1 and EL0 execute AArch64; retain all unrelated inherited bits. */
    mrs     x2, hcr_el2
    orr     x2, x2, #(1 << 31)
    msr     hcr_el2, x2

    adrp    x2, el1_vectors
    add     x2, x2, :lo12:el1_vectors
    msr     vbar_el1, x2
    msr     sp_el1, x0

    mov     x2, #0x3c5          /* EL1h, DAIF masked */
    msr     spsr_el2, x2
    msr     elr_el2, x1
    isb
    eret

/* el1_fpsimd_enable(): permit ordinary compiled code to use FP/SIMD if LLVM
 * selects it. Shared by .Lel1_entry and .Lsecondary_el1 (GitHub issue #224)
 * -- both used to set CPACR_EL1 separately, right after their own EL2->EL1
 * drop. */
    .global el1_fpsimd_enable
    .type el1_fpsimd_enable, %function
el1_fpsimd_enable:
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb
    ret

/* The hardware exception vector table (el1_vectors, referenced by
 * el2_drop_to_el1's `adrp x2, el1_vectors` / `msr vbar_el1, x2` above) is no
 * longer hand-laid-out here -- GitHub issue #227 item 2 replaced the former
 * 16-line VECTOR-macro table (eyeballed for slot coverage, with the
 * mov-x0-into-a-live-syscall-argument bug issue #227 item 3's own history
 * entry describes) with a `vector_table { N => target; ... }` declaration
 * in kernel/arch/arm64/kernel/vector_table.tkb, exhaustively checked by the
 * compiler (every one of AArch64's 16 architectural slots must be listed
 * exactly once) and emitted as the same shape of raw assembly this file
 * used to contain, via lib/llvm_gen.ml's gen_vector_table -- including the
 * exact fix for that bug: a target used by more than one slot gets
 * `mov x0, #slot` before the branch (so el1_exception_evidence can still
 * identify which slot fired), a target used by only one slot does not,
 * mechanically, with no hand-picked-register mistake possible. See that
 * file and HISTORY.md's issue #227 item 2 entry for the full design. */

/* el1_current_irq_entry (Current-EL-SPx IRQ, GitHub issue #187/#223) and
 * el0_irq_entry (Lower-EL AArch64 IRQ) are no longer hand-written here --
 * GitHub issue #227 item 1's prototype slice generates both, save/dispatch/
 * restore/eret in full, from kernel/arch/arm64/kernel/exception_frame.tkb's
 * `struct packed ExceptionFrame` and `exception_entry` declarations (lib/
 * llvm_gen.ml's gen_exception_entry), the same way item 2 above generates
 * el1_vectors. See that file and HISTORY.md's issue #227 item 1 entry for
 * the full design. `.Ldata_abort`/`el0_context_resume`/`run_initial_user`
 * (kernel/arch/arm64/kernel/user_entry.S) still use exception_context.inc's
 * EXC_CONTEXT_RESTORE directly -- restore-only, without a preceding save,
 * is out of this first slice's scope. */
