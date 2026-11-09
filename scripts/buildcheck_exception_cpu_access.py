#!/usr/bin/env python3
"""Check real exception-array boundaries without assuming a scoped manual mint.

Published record arrays reject slice decay in the compiler. Plain capture
arrays can decay under unscoped CpuHere, so the bounded source policy must
reject that same program. A global immutable mirror alias is tested separately.
"""

import argparse
from pathlib import Path

from check_exception_cpu_snapshots import PATH, problems
from kernel_compile_flags import kernel_compile_flags
from overlay_jobs import run_overlay_cases
from pass_line import report_pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', type=Path)
    parser.add_argument('sources', nargs='+')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    source = (repo / PATH).read_text(encoding='ascii')
    if problems(source):
        raise SystemExit('FAIL exception-cpu-access: production source policy is not positive')
    cases = []
    for section in ('capture', 'observed'):
        for field in ('trace', 'fd_kind', 'fd_object'):
            code = ('\nprivate fn exception_array_control(cpu: CpuHere) -> []usize { '
                    'return crash_snapshot_per_core[cpu].' + section + '.' + field + ' as []usize; }\n')
            cases.append((section + '.' + field, code, section == 'capture',
                          ('array payload field', 'pointer or a slice')))
    cases.append(('immutable global alias',
                  '\nprivate let mirror_alias: *CrashSnapshot = &crash_snapshot_published[0];\n',
                  False, ('global initializer: unsupported constant expression',)))
    for _, code, _, _ in cases:
        if not problems(source + code):
            raise SystemExit('FAIL exception-cpu-access: source policy missed an escape')

    for store, field, result_type in [
            ('ddb_stopped_root', 'pid', 'usize'),
            ('kernel_ddb_memory_access', 'address', 'usize'),
            ('crash_snapshot_capturing_per_core', 'active', 'bool'),
            ('crash_snapshot_per_core', 'capture.sequence', 'usize')]:
        code = ('\nprivate fn exception_integer_control(core: {0..<KERNEL_MAX_CORES as usize}) -> ' +
                result_type + ' { return ' + store + '[core].' + field + '; }\n')
        cases.append((store + ' integer index', code, False,
                      ('per-CPU store', 'indexed only by a CpuHere value')))
    for authority, accepts in [('MachineStopped', True), ('MachineStopPartial', False)]:
        code = ('\nprivate fn exception_stopped_control(stopped: borrow ' + authority +
                '[&kernel_world_stop], core: {0..<KERNEL_MAX_CORES as usize}) -> usize { '
                'return stopped_read(stopped, ddb_stopped_root[core].pid); }\n')
        cases.append((authority + ' peer read', code, accepts,
                      ('not a parameter of type `borrow MachineStopped',)))

    def judge(case, result):
        name, _, accepts, expected = case
        output = result.stdout + result.stderr
        if ((result.returncode == 0) == accepts and
                (accepts or all(part in output for part in expected))):
            return None
        return f'FAIL exception-cpu-access: {name}: status={result.returncode}\n{output}'

    failures = run_overlay_cases(
        repo, 'takibi-exception-cpu-access-', cases,
        lambda case: (Path(PATH), source + case[1]),
        lambda overlay: [str(args.compiler.resolve()), *args.sources, *kernel_compile_flags(),
                         '--internal-allow-unused', '-o', str(overlay / 'check.o')], judge)
    for failure in failures:
        if failure:
            print(failure)
    if any(failures):
        return 1
    report_pass('exception-cpu-access',
                'real arrays/global alias/integer CPU/partial-stop controls reject; complete-stop scalar read accepts; plain capture escape needs source policy',
                cases=len(cases))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
