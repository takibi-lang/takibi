/* SPDX-License-Identifier: MIT
 *
 * PMUv3 cycle-counter overflow sampling, for GitHub issue #500's flat PC
 * profile (kernel/kernel/profile_samples.tkb is the only caller).
 *
 * Assembly rather than .tkb because this kernel's mrs/msr support is a
 * CLOSED set of intrinsics (lib/type_inf.ml, lib/llvm_gen.ml -- see
 * kernel/arch/arm64/kernel/timer.tkb's header for the five that exist) and
 * none of them names a PMU register. Adding PMUv3 intrinsics is compiler
 * work; this task is a kernel task, so the eight system-register accesses
 * below stay here, in one file, with no logic of their own. Everything that
 * decides anything -- when to sample, what to keep, what was lost -- is in
 * the .tkb caller, where the type system can see it.
 *
 * Why the CYCLE counter and not an event counter: the cycle counter is the
 * one PMUv3 counter that is architecturally always present when PMUv3 is
 * (ID_AA64DFR0_EL1.PMUVer != 0/0xF), needs no event-number selection, and
 * needs no PMCEID capability check. A flat time profile wants elapsed
 * cycles anyway. Event counters, and the PMU's own state as a per-process
 * property, are not this issue's scope.
 *
 * The overflow bit for the cycle counter is bit 31 of every PMU bitmap
 * register (PMCNTENSET/CLR_EL0, PMINTENSET/CLR_EL1, PMOVSSET/CLR_EL0),
 * which is what the repeated `mov x1, #1; lsl x1, x1, #31` builds.
 */

    .section .text, "ax"

/* pmu_sample_supported() -> usize
 *
 * 1 when this CPU implements PMUv3, 0 otherwise. ID_AA64DFR0_EL1.PMUVer is
 * 0 for "not implemented" and 0xF for "IMPLEMENTATION DEFINED, not PMUv3";
 * every other value is a PMUv3 revision that has PMCCNTR_EL0 and its
 * overflow interrupt. Read before anything below is executed, so a CPU
 * without a PMU reports no samples instead of taking an undefined-
 * instruction exception on the first msr. */
    .global pmu_sample_supported
    .type pmu_sample_supported, %function
pmu_sample_supported:
    mrs     x1, id_aa64dfr0_el1
    ubfx    x1, x1, #8, #4
    mov     x0, #0
    cbz     x1, .Lsupported_done
    cmp     x1, #0xf
    b.eq    .Lsupported_done
    mov     x0, #1
.Lsupported_done:
    ret

/* pmu_sample_start(period: usize)
 *
 * Arms PMCCNTR_EL0 to overflow, and raise the PMU interrupt, after `period`
 * further cycles. PMCR_EL0.LC makes the counter 64-bit, so the reload value
 * is a plain two's-complement -period rather than a 32-bit wrap that would
 * have to be recomputed against the counter's width.
 *
 * PMCCFILTR_EL0 is zeroed deliberately: bit 31 (P) and bit 30 (U) would
 * exclude EL1 and EL0 respectively, and a profile that cannot see the
 * kernel is not the profile this exists to take. */
    .global pmu_sample_start
    .type pmu_sample_start, %function
pmu_sample_start:
    mov     x1, #1
    lsl     x1, x1, #31
    msr     pmcntenclr_el0, x1
    msr     pmintenclr_el1, x1
    msr     pmovsclr_el0, x1
    msr     pmccfiltr_el0, xzr
    mrs     x2, pmcr_el0
    orr     x2, x2, #(1 << 6)      /* LC: 64-bit cycle counter */
    bic     x2, x2, #(1 << 3)      /* D: count every cycle, not every 64th */
    orr     x2, x2, #(1 << 0)      /* E: enable the counters */
    msr     pmcr_el0, x2
    neg     x3, x0
    msr     pmccntr_el0, x3
    msr     pmcntenset_el0, x1
    msr     pmintenset_el1, x1
    isb
    ret

/* pmu_sample_pending() -> usize
 *
 * 1 when the cycle counter's overflow status bit is set. The interrupt
 * dispatcher asks this before recording, so a shared or spurious INTID
 * cannot be mistaken for an overflow this file armed. */
    .global pmu_sample_pending
    .type pmu_sample_pending, %function
pmu_sample_pending:
    mrs     x0, pmovsset_el0
    ubfx    x0, x0, #31, #1
    ret

/* pmu_sample_counter() -> usize
 *
 * The raw PMCCNTR_EL0. Diagnosis only: an interval that collected nothing
 * has two very different causes -- a counter that never counted, and a
 * counter that overflowed into an interrupt nobody delivered -- and this
 * plus pmu_sample_pending() tells them apart without a second board run. */
    .global pmu_sample_counter
    .type pmu_sample_counter, %function
pmu_sample_counter:
    mrs     x0, pmccntr_el0
    ret

/* pmu_sample_state() -> usize
 *
 * Diagnosis only, packed so one word answers the whole "is the PMU still
 * armed" question in a single line of UART output:
 *
 *   bit 0     PMINTENSET_EL1[31] -- the overflow INTERRUPT is enabled
 *   bit 1     PMCNTENSET_EL0[31] -- the cycle COUNTER is enabled
 *   bits 15:8 PMCR_EL0[7:0]      -- E/D/LC and friends
 *   bits 19:16 CurrentEL[3:2]    -- 1 for EL1, 2 for EL2
 *
 * A counter that overflowed with bit 0 clear never asserted the interrupt
 * line at all, which is a different bug from a line the interrupt
 * controller declined to forward. */
    .global pmu_sample_state
    .type pmu_sample_state, %function
pmu_sample_state:
    mrs     x1, pmintenset_el1
    ubfx    x0, x1, #31, #1
    mrs     x1, pmcntenset_el0
    ubfx    x1, x1, #31, #1
    orr     x0, x0, x1, lsl #1
    mrs     x1, pmcr_el0
    and     x1, x1, #0xff
    orr     x0, x0, x1, lsl #8
    mrs     x1, currentel
    ubfx    x1, x1, #2, #2
    orr     x0, x0, x1, lsl #16
    ret

/* pmu_sample_rearm(period: usize)
 *
 * Acknowledge the overflow and reload for the next one. Clearing
 * PMOVSCLR_EL0 is what deasserts the PMU interrupt line, so this must run
 * before the interrupt controller's EOI or the same interrupt is taken
 * again immediately. */
    .global pmu_sample_rearm
    .type pmu_sample_rearm, %function
pmu_sample_rearm:
    mov     x1, #1
    lsl     x1, x1, #31
    msr     pmovsclr_el0, x1
    neg     x2, x0
    msr     pmccntr_el0, x2
    isb
    ret

/* pmu_sample_stop()
 *
 * Disable the counter and its interrupt, and clear any overflow already
 * latched, so nothing arrives after the measured interval ends. PMCR_EL0.E
 * is deliberately left alone: it is a global enable other PMU users would
 * share, and this file did not necessarily set it. */
    .global pmu_sample_stop
    .type pmu_sample_stop, %function
pmu_sample_stop:
    mov     x1, #1
    lsl     x1, x1, #31
    msr     pmcntenclr_el0, x1
    msr     pmintenclr_el1, x1
    msr     pmovsclr_el0, x1
    isb
    ret

/* GitHub issue #503: two PMUv3 EVENT counters for measured questions, beside
 * the cycle counter above. Event counters 0 and 1, never PMCCNTR_EL0, so the
 * flat-PC sampler keeps its counter and neither user can reprogram the
 * other's. Counter 0 counts CPU_CYCLES (0x11), counter 1 INST_RETIRED
 * (0x08), both at EL0 and EL1 (the P and U filter bits are clear). They are
 * 32-bit counters without FEAT_PMUv3p5's PMCR_EL0.LP, so the caller takes
 * differences modulo 2^32 over intervals far shorter than a wrap. */

/* pmu_count_supported() -> usize
 *
 * 1 when this CPU implements PMUv3 and PMCR_EL0.N reports at least two
 * event counters, 0 otherwise. The ID register is read first, so a CPU
 * without PMUv3 never executes the PMCR_EL0 access. */
    .global pmu_count_supported
    .type pmu_count_supported, %function
pmu_count_supported:
    mrs     x1, id_aa64dfr0_el1
    ubfx    x1, x1, #8, #4
    mov     x0, #0
    cbz     x1, .Lcount_supported_done
    cmp     x1, #0xf
    b.eq    .Lcount_supported_done
    mrs     x1, pmcr_el0
    ubfx    x1, x1, #11, #5
    cmp     x1, #2
    b.lo    .Lcount_supported_done
    mov     x0, #1
.Lcount_supported_done:
    ret

/* pmu_count_start()
 *
 * Program and enable both event counters on this CPU. Idempotent, and it
 * does not reset their values: callers only ever take differences. PMCR_EL0.E
 * is the global enable the sampler also sets; this sets it and never clears
 * it. */
    .global pmu_count_start
    .type pmu_count_start, %function
pmu_count_start:
    mov     x1, #0x11
    msr     pmevtyper0_el0, x1
    mov     x1, #0x08
    msr     pmevtyper1_el0, x1
    mrs     x2, pmcr_el0
    orr     x2, x2, #(1 << 0)      /* E: enable the counters */
    msr     pmcr_el0, x2
    mov     x1, #3
    msr     pmcntenset_el0, x1
    isb
    ret

/* pmu_count_cycles() -> usize, pmu_count_instructions() -> usize
 *
 * The raw 32-bit values of event counters 0 and 1. */
    .global pmu_count_cycles
    .type pmu_count_cycles, %function
pmu_count_cycles:
    isb
    mrs     x0, pmevcntr0_el0
    ret

    .global pmu_count_instructions
    .type pmu_count_instructions, %function
pmu_count_instructions:
    isb
    mrs     x0, pmevcntr1_el0
    ret
