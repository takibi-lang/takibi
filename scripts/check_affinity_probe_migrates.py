#!/usr/bin/env python3
"""Keep the existing affinity/GDB lane tied to symmetric dispatch (#1330).

The historical filename names the gate the lane used to exercise. The probe
and watcher must now agree on a call handled on its admitted CPU, and must
retain the post-call getcpu check rather than assert a forced core-0 rerun.
"""
import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only, per_file

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE = ROOT / 'kernel/arch/arm64/kernel/affinity_probe.tkb'
WATCHER = ROOT / 'scripts/kernel_affinity_gdb_check.py'
SYSCALL = ROOT / 'kernel/kernel/syscall.tkb'


@per_file
def source(text):
    return code_only(text)


def problems(probe, watcher, syscall):
    code = source(probe)
    errors = []
    said = re.search(r'affinity: pinned to cpu 1, where (\w+) answered without rerouting', code)
    if said is None:
        return ['probe no longer prints its symmetric-dispatch verdict']
    name = said[1].upper() + '_SYSCALL'
    value = re.search(rf'\bconst {name}: usize = (\d+);', code)
    watched = re.search(r'^DISPATCHED_SYSCALL = (\d+)$', watcher, re.M)
    if value is None or f'svc5({name},' not in code:
        errors.append('probe must declare and issue its reported syscall')
    if value is None or watched is None or value[1] != watched[1]:
        errors.append('probe and GDB watcher disagree on the dispatched syscall')
    if 'affinity_cpu(cpu_bytes as []u8) != 1' not in code:
        errors.append('probe must check its CPU after the reported syscall')
    if 'HANDLER = "*kernel_process_uart_record_parent_progress"' not in watcher:
        errors.append('GDB must watch the actual parent-progress handler')
    if 'handler.condition = f"$_thread == {CPU1_THREAD}"' not in watcher:
        errors.append('GDB handler observation must be on CPU 1')
    if 'resumed.condition = f"$x1 == {GETCPU_SYSCALL} && $_thread == {CPU1_THREAD}"' not in watcher:
        errors.append('GDB must watch the next getcpu on CPU 1')
    if re.search(r'\bsyscall_peer_(?:safe|refused)\s*\(', source(syscall)):
        errors.append('retired core-0 syscall admission gate is still present')
    return errors


def main():
    texts = {path: path.read_text() for path in (PROBE, WATCHER, SYSCALL)}
    errors = problems(texts[PROBE], texts[WATCHER], texts[SYSCALL])
    for error in errors:
        print('ERROR affinity-probe-migrates: ' + error)
    if errors:
        return 1
    report_pass('affinity-probe-migrates',
                'probe and GDB observe symmetric handler dispatch and return on CPU 1',
                files=len(texts))
    return 0


if __name__ == '__main__':
    sys.exit(main())
