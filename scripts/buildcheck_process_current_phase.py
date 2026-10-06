#!/usr/bin/env python3
"""Compile real process APIs to reject current authority across phase changes."""

import argparse
from pathlib import Path
import subprocess
import tempfile

from pass_line import CaseCount, report_pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('sources', nargs='+')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    compiler = args.compiler.resolve()
    process = Path('kernel/kernel/process.tkb')
    source = (repo / process).read_text(encoding='ascii')
    cases = []
    for phase, transition, extra in [
            ('Running', 'scheduled_process_yield', ''),
            ('Running', 'scheduled_process_block', ', ProcessWaitReason::ChildExit'),
            ('Running', 'scheduled_process_exit', ''),
            ('Constructing', 'scheduled_process_finish_clone', ', frame'),
            ('Constructing', 'scheduled_process_cancel_clone', '')]:
        cases.append((transition, f'''
private fn current_phase_control(
        current: borrow ProcessCurrent[process, ProcessState::{phase}],
        owner: borrow ScheduledProcessOwner[process],
        state: sink ScheduledProcessState[process, ProcessState::{phase}],
        frame: borrow FrameRef[frame_process]) -> usize {{
    let next = {transition}(owner, state{extra});
    let pid: usize = scheduled_process_record_current(current).pid;
    scheduled_process_state_drop(next);
    return pid;
}}
''', False))
    for reset in ['scheduled_process_table_clear', 'scheduled_process_table_init']:
        cases.append((reset, f'''
private fn current_phase_control(
        current: borrow ProcessCurrent[process, ProcessState::Running]) -> usize {{
    {reset}();
    return scheduled_process_record_current(current).pid;
}}
''', False))
    cases.append(('consume before transition', '''
private fn current_phase_control(
        current: ProcessCurrent[process, ProcessState::Running],
        owner: borrow ScheduledProcessOwner[process],
        state: sink ScheduledProcessState[process, ProcessState::Running]) -> usize {
    let pid: usize = scheduled_process_record_current(current).pid;
    process_current_end(current);
    let next = scheduled_process_yield(owner, state);
    scheduled_process_state_drop(next);
    return pid;
}
''', True))
    ran = CaseCount()
    with tempfile.TemporaryDirectory(prefix='takibi-current-phase-') as tmp:
        overlay = Path(tmp)
        for original in (repo / 'kernel').rglob('*'):
            target = overlay / original.relative_to(repo)
            if original.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif original.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(original)
        target = overlay / process
        target.unlink()
        for name, addition, accepts in cases:
            target.write_text(source + addition, encoding='ascii')
            result = subprocess.run(
                [str(compiler), *args.sources, '--regions', '--forbid-trap',
                 '--target', 'aarch64-none-elf', '--cpu', 'cortex-a53',
                 '--emit-struct-layout', 'ProcessRecord', '-o', str(overlay / 'layout')],
                cwd=overlay, capture_output=True, text=True, check=False)
            ran.note()
            output = result.stdout + result.stderr
            status_ok = (result.returncode == 0) == accepts
            diagnostic_ok = accepts or 'contains a live ProcessCurrent witness' in output
            if not status_ok or not diagnostic_ok:
                print(f'FAIL process-current-phase: {name}: status={result.returncode}\n{output}')
                return 1
    report_pass('process-current-phase',
                'five phase transitions and both table resets reject retained current authority; consumption permits transition',
                cases=ran.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
