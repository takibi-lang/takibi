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
    cases.extend([
        ('activation rejects reconstructed root', """
private fn root_entry_control(word: usize) {
    process_image_activate_root(address_space_root_of_key(word));
}
""", False, 'cannot unify AddressSpaceRoot with view ProcessCurrent'),
        ('prepared commit rejects another owner generation', """
private fn root_entry_control(
        owner: borrow ScheduledProcessOwner[process],
        running: borrow ScheduledProcessState[process, ProcessState::Running],
        other: borrow ScheduledProcessOwner[another],
        other_running: borrow ScheduledProcessState[another, ProcessState::Running]) -> bool {
    match process_image_prepare_activation(owner, running) {
        AddressSpaceActivationPrepareResult::Invalid => { return false; }
        AddressSpaceActivationPrepareResult::RolloverNeeded => { return false; }
        AddressSpaceActivationPrepareResult::Prepared(prepared) => {
            return process_image_commit_activation(other, other_running, prepared);
        }
    }
}
""", False, 'static value mismatch'),
        ('prepared commit retains real authority', """
private fn root_entry_control(
        owner: borrow ScheduledProcessOwner[process],
        running: borrow ScheduledProcessState[process, ProcessState::Running]) -> bool {
    match process_image_prepare_activation(owner, running) {
        AddressSpaceActivationPrepareResult::Invalid => { return false; }
        AddressSpaceActivationPrepareResult::RolloverNeeded => { return false; }
        AddressSpaceActivationPrepareResult::Prepared(prepared) => {
            return process_image_commit_activation(owner, running, prepared);
        }
    }
}
""", True, ''),
        ('prepared expiry through real borrowed teardown', """
private fn root_entry_control(
        owner: sink ScheduledProcessOwner[process],
        running: sink ScheduledProcessState[process, ProcessState::Running]) -> bool {
    let mut handle: ProcessHandle = { owner.pool_index, owner.generation };
    match process_image_prepare_activation(owner, running) {
        AddressSpaceActivationPrepareResult::Invalid => { return false; }
        AddressSpaceActivationPrepareResult::RolloverNeeded => { return false; }
        AddressSpaceActivationPrepareResult::Prepared(prepared) => {
            let guard = process_run_lock();
            let exited = scheduled_process_exit(owner, running);
            scheduled_process_release(owner, exited);
            match scheduled_process_exited_take(guard, handle) {
                ScheduledProcessExitedTakeResult::Missing => {
                    process_run_unlock(guard);
                    process_image_cancel_activation(prepared);
                    return false;
                }
                ScheduledProcessExitedTakeResult::Exited(resources) => {
                    let (reaper, reaping) = resources;
                    process_run_unlock(guard);
                    scheduled_process_reap_teardown(reaper, reaping);
                    let committed: bool = process_image_commit_activation(reaper, reaping, prepared);
                    let removal = process_run_lock();
                    scheduled_process_reap_remove(removal, reaper, reaping);
                    process_run_unlock(removal);
                    return committed;
                }
            }
        }
    }
}
""", False, 'ProcessState::Reapable'),
    ])
    cases.extend([
        ('permanent boot prepared activation', """
private fn root_boot_control() -> bool {
    match address_space_prepare_boot_activation() {
        AddressSpaceActivationPrepareResult::Invalid => { return false; }
        AddressSpaceActivationPrepareResult::RolloverNeeded => { return false; }
        AddressSpaceActivationPrepareResult::Prepared(prepared) => {
            match address_space_commit_boot_activation(prepared) {
                AddressSpaceActivationCommitResult::Invalid => { return false; }
                AddressSpaceActivationCommitResult::Activated(root) => {
                    return root_slot_word(address_space_root_slot(root)) == 0;
                }
            }
        }
    }
}
""", True, ''),
        ('owner prepared token is not boot authority', """
private fn root_boot_control(
        owner: borrow ScheduledProcessOwner[process],
        running: borrow ScheduledProcessState[process, ProcessState::Running]) -> bool {
    match process_image_prepare_activation(owner, running) {
        AddressSpaceActivationPrepareResult::Invalid => { return false; }
        AddressSpaceActivationPrepareResult::RolloverNeeded => { return false; }
        AddressSpaceActivationPrepareResult::Prepared(prepared) => {
            match address_space_commit_boot_activation(prepared) {
                AddressSpaceActivationCommitResult::Invalid => { return false; }
                AddressSpaceActivationCommitResult::Activated(root) => { return true; }
            }
        }
    }
}
""", False, 'static value mismatch'),
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
                'current phases, borrowed teardown, reconstructed roots, wrong-generation commits and prepared expiry are checked on real kernel APIs',
                cases=ran.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
