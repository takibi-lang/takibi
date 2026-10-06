#!/usr/bin/env python3
"""Mutation controls for the trusted current-process witness boundary."""

from check_process_running_mints import ROOT, problems
from pass_line import report_pass


def main():
    sources = {str(path): path.read_text() for path in ROOT.rglob('*.tkb')
               if 'build' not in path.parts}
    assert not problems(sources)
    path = 'kernel/kernel/process.tkb'
    original = sources[path]
    controls = {
        'public witness': original.replace('private linear view ProcessCurrent[',
                                           'linear view ProcessCurrent[', 1),
        'public constructor': original.replace('private inline fn process_running_new(',
                                               'inline fn process_running_new(', 1),
        'missing context marker': original.replace('!{changes_witness_ProcessCurrent}', '', 1),
        'commented context marker': original.replace('!{changes_witness_ProcessCurrent}',
                                                     '// !{changes_witness_ProcessCurrent}\n', 1),
        'new inline entry mint': original + '\ninline fn unreviewed() { process_running_here(); }\n',
        'additional entry mint': original.replace('process_running_new(execution_here()',
                                                 'process_running_here(); process_running_new(execution_here()', 1),
        'global mint': original + '\nlet unreviewed = view ProcessCurrent[0, ProcessState::Running];\n',
        'new direct mint': original + '\nfn unreviewed() { view ProcessCurrent[0, ProcessState::Running]; }\n',
        'new unmarked writer': original + '\nfn unreviewed() { execution_here().current_live = false; }\n',
    }
    for name, changed in controls.items():
        assert changed != original, name
        assert problems({**sources, path: changed}), name
    assert not problems({**sources, path: original +
                         '\n// process_running_here(); execution_here().current_live = false;\n'}), 'prose is not code'
    report_pass('process-running-mints controls',
                f'production passes and {len(controls)} trusted-boundary regressions fail',
                controls=len(controls))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
