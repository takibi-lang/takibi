#!/usr/bin/env python3
"""Faithful alias/association controls for unscoped exception CPU authority."""

from pathlib import Path
from check_exception_cpu_snapshots import PATH, MIRROR, CALLERS, problems
from buildcheck_global_protection import exception_publication_admitted, parse_table, TableError, COLUMNS
from buildcheck_allowed_callers import read_list
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
    cases.extend([
        source + '\nprivate let mirror_alias: *CrashSnapshot = &crash_snapshot_published[0];\n',
        replace_in_function(source, 'fn crash_snapshot_publish(',
            'write.process_pid = crash_snapshot_per_core[cpu].capture.process_pid;',
            'write.process_pid = crash_snapshot_per_core[cpu].capture.process_pid; write.process_pid = 0;'),
        source + '\nfn rearm(cpu: CpuHere) { crash_snapshot_capturing_per_core[cpu].active = (0 == 1); }\n',
        source + '\nfn rearm(cpu: CpuHere) { let inactive = false; crash_snapshot_capturing_per_core[cpu].active = inactive; }\n',
    ])
    for section in ('capture', 'observed'):
        for field in ('trace', 'fd_kind', 'fd_object'):
            cases.append(source + '\nfn escape(cpu: CpuHere) -> []usize { return crash_snapshot_per_core[cpu].' + section + '.' + field + ' as []usize; }\n')
    cases.extend([
        source + '\nfn escape(cpu: CpuHere) -> *CrashCapture { return &(crash_snapshot_per_core[cpu].capture); }\n',
        replace_in_function(source, 'fn crash_snapshot_copy_published(',
            'if (taken == 0)', 'if (taken == 99)'),
        replace_in_function(source, 'fn crash_snapshot_render_every_core(',
            'CrashSnapshotReadResult::Unpublished => { continue; }',
            'CrashSnapshotReadResult::Unpublished => {}'),
    ])
    cases.append(replace_in_function(source, 'fn crash_world_stop_report(',
        'crash_snapshot_shared_stopped(cpu, stopped);', 'crash_snapshot_shared_stopped(cpu, stopped); crash_snapshot_publish(cpu);'))
    rules = read_list()
    row = dict(file=PATH, name=MIRROR, visibility='private', qualifier='-',
               type='[CrashSnapshot;4]', protection='none')
    # Synthetic graph isolates admission logic. Both actual compiler tables are
    # checked by global_protection.ok, including planted foreign/pointer calls.
    table = []
    for helper, callers in CALLERS.items():
        for name in callers:
            table.append(dict(file=PATH, name=name, callees=[helper + '@-'], values=[]))
    table.append(dict(file=PATH, name='foreign', callees=[], values=[]))
    admits = lambda text=source, graph=table, policy=rules, record=row: exception_publication_admitted(
        record, 'missing/globals.tsv', source=text, table=graph, rules=policy)
    assert admits()
    for changed in cases:
        assert problems(changed)
        assert not admits(text=changed)
    for key, value in [('file', 'kernel/elsewhere.tkb'), ('name', 'other'),
                       ('visibility', 'public'), ('qualifier', 'scratch'),
                       ('type', '[PlainSnapshot;4]')]:
        assert not admits(record=dict(row, **{key: value}))
    aliased = [dict(r) for r in table]
    aliased[0] = dict(aliased[0], values=['crash_snapshot_capture@-'])
    assert not admits(graph=aliased)
    assert not admits(graph=[])
    assert not admits(policy=[])
    for kind in ('callees', 'values'):
        changed = [dict(r) for r in table]
        changed[-1] = dict(changed[-1], **{kind: ['crash_snapshot_publish@-']})
        assert not admits(graph=changed)
    assert not exception_publication_admitted(row, 'missing/globals.tsv')
    forged = dict(row, line='1', protection='exception_publication')
    raw = '# takibi globals, format 3\n' + '\t'.join(COLUMNS) + '\n' + '\t'.join(forged[k] for k in COLUMNS)
    try:
        parse_table(raw, 'forged')
    except TableError as error:
        assert 'derived only by the scoped build admission' in str(error)
    else:
        raise AssertionError('a raw protection label bypassed scoped admission')
    assert not problems(source + '\n// &crash_snapshot_per_core[cpu].capture is prose.\n')
    report_pass('exception-cpu-snapshots controls',
                'production/prose pass; payload escapes, extra writers, field/slot substitution and capture rearming fail',
                controls=len(cases))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
