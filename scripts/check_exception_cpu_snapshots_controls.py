#!/usr/bin/env python3
"""Faithful alias/association controls for unscoped exception CPU authority."""

from pathlib import Path
from check_exception_cpu_snapshots import PATH, problems
from control_patch import replace_once, replace_in_function
from pass_line import report_pass


def main():
    source = Path(PATH).read_text()
    assert not problems(source)
    cases = [
        source + '\nfn escape(cpu: CpuHere) -> *CrashCapture { return &crash_snapshot_per_core[cpu].capture; }\n',
        source + '\nfn escape(cpu: CpuHere) -> *usize { return crash_snapshot_per_core[cpu].capture.trace as *usize; }\n',
        source + '\nfn escape() { let array = crash_snapshot_per_core; }\n',
        source + '\nfn extra(core: {0..<KERNEL_MAX_CORES as usize}) { publish_begin(&crash_snapshot_published[core]); }\n',
        replace_in_function(source, 'fn crash_snapshot_copy_published(',
                            '&crash_snapshot_per_core[cpu].observed',
                            '&crash_snapshot_per_core[cpu].observed); let alias = (&crash_snapshot_per_core[cpu].observed'),
        replace_in_function(source, 'fn crash_snapshot_publish(',
                            'write.process_pid = crash_snapshot_per_core[cpu].capture.process_pid;',
                            'write.process_pid = crash_snapshot_per_core[cpu].capture.parent_pid;'),
        replace_in_function(source, 'fn crash_snapshot_publish(',
                            'let core: {0..<KERNEL_MAX_CORES as usize} = cpu_here_index(cpu);',
                            'let core: {0..<KERNEL_MAX_CORES as usize} = 0;'),
        replace_in_function(source, 'fn crash_snapshot_publish(',
                            'publish_commit(write, crash_snapshot_per_core[cpu].capture.sequence);',
                            'publish_commit(write, 1);'),
        source + '\nfn reset(cpu: CpuHere) { crash_snapshot_capturing_per_core[cpu].active = false; }\n',
        replace_once(source, 'struct publish CrashSnapshot {', 'struct CrashSnapshot {'),
    ]
    for changed in cases:
        assert problems(changed)
    assert not problems(source + '\n// &crash_snapshot_per_core[cpu].capture is prose.\n')
    report_pass('exception-cpu-snapshots controls',
                'production/prose pass; payload escapes, extra writers, field/slot substitution and capture rearming fail',
                controls=len(cases))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
