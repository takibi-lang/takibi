#!/usr/bin/env python3
"""Mutation controls for the trusted current-process witness boundary."""

from control_patch import replace_once
from check_process_running_mints import ROOT, problems
from pass_line import report_pass


def main():
    sources = {str(path): path.read_text() for path in ROOT.rglob('*.tkb')
               if 'build' not in path.parts}
    assert not problems(sources)
    path = 'kernel/kernel/process.tkb'
    original = sources[path]
    # GitHub issue #845: the context marker repeats; these controls name the
    # first function's copy by its signature.
    site = '        frame: borrow FrameRef[frame_process])\n        -> ScheduledProcessState[process, ProcessState::Running] '
    controls = {
        'public witness': replace_once(original, 'private linear view ProcessCurrent[', 'linear view ProcessCurrent['),
        'public constructor': replace_once(original, 'private inline fn process_running_new(', 'inline fn process_running_new('),
        'missing context marker': replace_once(original, site + '!{changes_witness_ProcessCurrent}', site),
        'commented context marker': replace_once(original, site + '!{changes_witness_ProcessCurrent}', site + '// !{changes_witness_ProcessCurrent}\n'),
        # GitHub issue #818: a block comment is a comment too.
        'block-commented context marker': replace_once(original, site + '!{changes_witness_ProcessCurrent}', site + '/* !{changes_witness_ProcessCurrent} */'),
        'new inline entry mint': original + '\ninline fn unreviewed() { process_running_here(); }\n',
        'additional entry mint': replace_once(original, 'process_running_new(execution_state[execution_cpu_index()]', 'process_running_here(); process_running_new(execution_state[execution_cpu_index()]'),
        'global mint': original + '\nlet unreviewed = view ProcessCurrent[0, ProcessState::Running];\n',
        'new direct mint': original + '\nfn unreviewed() { view ProcessCurrent[0, ProcessState::Running]; }\n',
        'new unmarked writer': original + '\nfn unreviewed() { execution_state[execution_cpu_index()].current_live = false; }\n',
        'new unmarked phase writer': original + '''
fn unreviewed(owner: borrow ScheduledProcessOwner[process],
        state: sink ScheduledProcessState[process, ProcessState::Running]) {
    scheduled_process_state_drop(state);
    scheduled_process_record_owned(owner).state = ProcessSlotState::Exited;
}
''',
        'new unmarked phase transition': original + '''
fn unreviewed(owner: borrow ScheduledProcessOwner[process],
        state: sink ScheduledProcessState[process, ProcessState::Running]) {
    scheduled_process_state_drop(state);
    process_state_exit(&scheduled_process_record_owned(owner).state);
}
''',
    }
    for name, changed in controls.items():
        assert changed != original, name
        assert problems({**sources, path: changed}), name
    for function in ['scheduled_process_finish_clone', 'scheduled_process_cancel_clone',
                     'scheduled_process_yield', 'scheduled_process_block',
                     'scheduled_process_exit', 'scheduled_process_release_every_process']:
        start = original.index('fn ' + function + '(')
        marker = original.index('changes_witness_ProcessCurrent', start)
        # Cut at the found position: unique by construction.
        changed = (original[:marker] +
                   original[marker + len('changes_witness_ProcessCurrent'):])
        assert problems({**sources, path: changed}), function
        controls[function] = changed
    assert not problems({**sources, path: original +
                         '\n// process_running_here(); execution_state[execution_cpu_index()].current_live = false;\n'}), 'prose is not code'
    assert not problems({**sources, path: original +
                         '\n/* process_running_here(); { */\n'}), 'block prose is not code'
    report_pass('process-running-mints controls',
                f'production passes and {len(controls)} trusted-boundary regressions fail',
                controls=len(controls))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
