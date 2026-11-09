#!/usr/bin/env python3
"""Compile real process APIs to reject current authority across phase changes."""

import argparse
from pathlib import Path

from kernel_compile_flags import kernel_compile_flags
from overlay_jobs import run_overlay_cases
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
    # GitHub issue #829: the block queues on a tick-wake list, so it takes
    # the run guard first.
    for phase, transition, lead, extra in [
            ('Running', 'scheduled_process_yield', '', ''),
            ('Running', 'scheduled_process_block', 'guard, ', ', ProcessWaitReason::ChildExit'),
            ('Running', 'scheduled_process_exit', '', ''),
            ('Constructing', 'scheduled_process_finish_clone', '', ', frame'),
            ('Constructing', 'scheduled_process_cancel_clone', '', '')]:
        cases.append((transition, f'''
private fn current_phase_control(
        guard: borrow ProcessRunGuard[&scheduled_process_run_lock],
        current: borrow ProcessCurrent[process, ProcessState::{phase}],
        owner: borrow ScheduledProcessOwner[process],
        state: sink ScheduledProcessState[process, ProcessState::{phase}],
        frame: borrow FrameRef[frame_process, level]) -> usize {{
    let next = {transition}({lead}owner, state{extra});
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
    # Teardown ends the root before the owner is sunk into removal. Exercise
    # the real API, including borrowed invalidation rather than only a sink.
    cases.extend([
        ('teardown requires Reapable', """
private fn root_teardown_control(
        owner: borrow ScheduledProcessOwner[process],
        state: borrow ScheduledProcessState[process, ProcessState::Running]) {
    scheduled_process_reap_teardown(owner, state);
}
""", False, 'static'),
        ('teardown rejects another generation', """
private fn root_teardown_control(
        owner: borrow ScheduledProcessOwner[process],
        state: borrow ScheduledProcessState[other, ProcessState::Reapable]) {
    scheduled_process_reap_teardown(owner, state);
}
""", False, 'static'),
        ('teardown invalidates borrowed record', """
private fn root_teardown_control(
        owner: borrow ScheduledProcessOwner[process],
        state: borrow ScheduledProcessState[process, ProcessState::Reapable]) -> usize {
    let record = scheduled_process_record_owned(owner);
    scheduled_process_reap_teardown(owner, state);
    return record.pid;
}
""", False, 'may invalidate live derived value'),
        ('teardown after completed loan', """
private fn root_teardown_control(
        owner: borrow ScheduledProcessOwner[process],
        state: borrow ScheduledProcessState[process, ProcessState::Reapable]) -> usize {
    let pid: usize = scheduled_process_record_owned(owner).pid;
    scheduled_process_reap_teardown(owner, state);
    return pid;
}
""", True, ''),
    ])
    def judge(case, result):
        name, _, accepts = case[:3]
        output = result.stdout + result.stderr
        status_ok = (result.returncode == 0) == accepts
        expected = case[3] if len(case) == 4 else 'contains a live ProcessCurrent witness'
        diagnostic_ok = accepts or expected in output
        if status_ok and diagnostic_ok:
            return None
        return f'FAIL process-current-phase: {name}: status={result.returncode}\n{output}'

    failures = run_overlay_cases(
        repo, 'takibi-current-phase-', cases,
        lambda case: (process, source + case[1]),
        lambda overlay: [str(compiler), *args.sources, *kernel_compile_flags(), '--internal-allow-unused',
                         '-o', str(overlay / 'check.o')],
        judge)
    ran = CaseCount()
    for failure in failures:
        ran.note()
        if failure is not None:
            print(failure)
    if any(failures):
        return 1
    report_pass('process-current-phase',
                'phase transitions and resets reject retained current authority; teardown requires matching Reapable state and rejects live record loans',
                cases=ran.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
