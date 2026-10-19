#!/usr/bin/env python3
"""Controls for check_guest_syscalls_dispatched.py (#792)."""

from control_patch import replace_once
from check_guest_syscalls_dispatched import SYSCALL_TKB, kernel_sources, problems
from pass_line import report_pass

PROBE = 'kernel/arch/arm64/kernel/protocol_trace_probe.tkb'
ASM = 'kernel/arch/arm64/kernel/signal_boundary_asm.S'
C_WORKLOAD = 'kernel/benchmarks/service_space/workload.c'
YIELD_ARM = 'if (number == AARCH64_NR_SCHED_YIELD) {'


def main() -> int:
    sources = kernel_sources()
    assert not problems(sources), problems(sources)
    kernel = sources[SYSCALL_TKB]
    probe = sources[PROBE]
    assert kernel.count(YIELD_ARM) == 2  # syscall_peer_safe, then dispatch
    controls = {
        # #665 itself: the probe issues 124 and the kernel has no arm for it.
        # Only the dispatch function's arm counts; the peer-safety helper's
        # comparison with the same constant is not a dispatch.
        'sched_yield arm removed': {SYSCALL_TKB: 'if (number == 99999) {'.join(
            kernel.rsplit(YIELD_ARM, 1))},
        'unused probe constant for an undispatched number': {
            PROBE: probe + '\nconst SCHED_RR_INTERVAL_SYSCALL: usize = 127;\n'},
        'literal svc for an undispatched number': {
            PROBE: probe + '\nfn control() { svc5(127, 0, 0, 0, 0, 0); }\n'},
        'hex const svc for an undispatched number': {
            PROBE: probe + '\nconst CONTROL_NR: usize = 0x7F;\n'
                           'fn control() { svc5(CONTROL_NR, 0, 0, 0, 0, 0); }\n'},
        'svc number the check cannot read': {
            PROBE: probe + '\nfn control(n: usize) { svc5(n, 0, 0, 0, 0, 0); }\n'},
        'asm mov x8 for an undispatched number': {
            ASM: sources[ASM] + '\n    mov x8, #127\n    svc #0\n'},
        'C raw-ABI call for an undispatched number': {
            C_WORKLOAD: replace_once(sources[C_WORKLOAD], 'call(172,', 'call(127,')},
    }
    for name, change in controls.items():
        for path, text in change.items():
            assert text != sources[path], name
        assert problems({**sources, **change}), name
    # The reviewed list accepts a listed number and refuses stale entries.
    undispatched = {PROBE: probe + '\nconst SCHED_RR_INTERVAL_SYSCALL: usize = 127;\n'}
    assert not problems({**sources, **undispatched}, {127: 'control'}), 'expected'
    assert problems(sources, {127: 'stale: nobody issues it'}), 'stale unissued'
    assert problems(sources, {124: 'stale: dispatched'}), 'stale dispatched'
    # Prose is not code.
    assert not problems({**sources, PROBE: probe +
                         '\n// const X_SYSCALL: usize = 127; svc5(127, 0)\n'}), 'comment'
    report_pass('guest-syscalls-dispatched controls',
                f'production passes and {len(controls) + 2} undispatched or stale shapes fail',
                controls=len(controls) + 2)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
