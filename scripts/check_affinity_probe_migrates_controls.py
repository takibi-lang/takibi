#!/usr/bin/env python3
"""Controls for the replacement symmetric-dispatch affinity/GDB contract."""
import sys

from check_affinity_probe_migrates import PROBE, WATCHER, SYSCALL, problems
from pass_line import report_pass


def main():
    probe, watcher, syscall = (path.read_text() for path in (PROBE, WATCHER, SYSCALL))
    assert not problems(probe, watcher, syscall)
    cases = [
        (probe.replace('answered without rerouting', 'done'), watcher, syscall),
        (probe.replace('svc5(PARENT_PROGRESS_SYSCALL,', 'svc5(WRITE_SYSCALL,'), watcher, syscall),
        (probe, watcher.replace('DISPATCHED_SYSCALL = 452', 'DISPATCHED_SYSCALL = 160'), syscall),
        (probe.replace('affinity_cpu(cpu_bytes as []u8) != 1', 'false'), watcher, syscall),
        (probe, watcher.replace('*kernel_process_uart_record_parent_progress', '*kernel_syscall_migrate_return'), syscall),
        (probe, watcher.replace('handler.condition = f"$_thread == {CPU1_THREAD}"', 'handler.condition = "true"'), syscall),
        (probe, watcher.replace('resumed.condition = f"$x1 == {GETCPU_SYSCALL} && $_thread == {CPU1_THREAD}"', 'resumed.condition = "true"'), syscall),
        (probe, watcher, syscall + '\nfn syscall_peer_safe(n: usize) -> bool { return false; }\n'),
        (probe, watcher, syscall + '\nfn syscall_peer_refused(n: usize) -> bool { return true; }\n'),
    ]
    for i, args in enumerate(cases):
        assert problems(*args), f'planted defect {i} passed'
    report_pass('affinity-probe-migrates controls',
                'repository passes; missing, mismatched, unissued and rerouted evidence is refused',
                cases=len(cases) + 1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
