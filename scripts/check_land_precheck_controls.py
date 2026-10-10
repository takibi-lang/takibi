#!/usr/bin/env python3
"""Run the real publication shell with deterministic local command providers.

No Git repository, network, board, suite lease or actual build is touched.
The trace verifies which make/git operations the shell really requests.
"""
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

PROVIDER = r'''#!/bin/sh
command=${0##*/}
trace="$TAKIBI_LAND_CONTROL_ROOT/trace.tsv"
printf '%s' "$command" >> "$trace"
for argument in "$@"; do printf '\t%s' "$argument" >> "$trace"; done
printf '\n' >> "$trace"
case "$command" in
    make)
        if [ "$1" = langcheck ] && [ -n "$TAKIBI_LAND_CONTROL_MODEL" ]; then
            exec "$TAKIBI_LAND_CONTROL_PYTHON" "$TAKIBI_LAND_CONTROL_MODEL" "$TAKIBI_LAND_CONTROL_ROOT/stale-readme.md"
        fi
        if [ "$1" = "$TAKIBI_LAND_CONTROL_FAIL" ]; then
            printf 'fixture diagnostic: %s\n' "$1"
            exit 7
        fi
        printf 'fixture pass: %s\n' "$1"
        ;;
    python3) exit 0 ;;
    git)
        case "$*" in
            'rev-parse --show-toplevel') printf '%s\n' "$TAKIBI_LAND_CONTROL_ROOT" ;;
            'symbolic-ref --quiet --short HEAD') printf 'main\n' ;;
            'rev-parse HEAD') printf '1111111111111111111111111111111111111111\n' ;;
            'rev-parse origin/main')
                if [ -n "$TAKIBI_LAND_CONTROL_EQUAL" ]; then
                    printf '1111111111111111111111111111111111111111\n'
                else
                    printf '2222222222222222222222222222222222222222\n'
                fi
                ;;
            'status --porcelain --untracked-files=no') : ;;
            'log -1 --format=%an'|'log -1 --format=%ae') printf 'Fixture\n' ;;
            pull*|fetch*|push*|merge-base*) : ;;
            *) printf 'unexpected git command: %s\n' "$*" >&2; exit 42 ;;
        esac
        ;;
    *) printf 'unexpected provider: %s\n' "$command" >&2; exit 42 ;;
esac
'''


def run_case(source, fail='', equal=False, real_model=False):
    with tempfile.TemporaryDirectory(prefix='takibi-land-precheck-') as tmp:
        root = Path(tmp)
        (root / 'scripts').mkdir()
        (root / 'scripts/land.sh').write_text(source)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        for name in ('git', 'make', 'python3'):
            script = bin_dir / name
            script.write_text(PROVIDER)
            script.chmod(0o755)
        model_runner = ''
        if real_model:
            repo = Path(__file__).resolve().parents[1]
            readme = (repo / 'kernel/models/README.md').read_text()
            stale, changed = re.subn(r"\| `[0-9a-f]{12}` \|", '| `000000000000` |', readme, count=1)
            assert changed == 1
            (root / 'stale-readme.md').write_text(stale)
            runner = root / 'real-model-check.py'
            runner.write_text('import sys, pathlib\n'
                              'sys.dont_write_bytecode = True\n'
                              'sys.path.insert(0, ' + repr(str(repo / 'scripts')) + ')\n'
                              'import check_model_function_map as check\n'
                              'check.README = pathlib.Path(sys.argv[1])\n'
                              'raise SystemExit(check.main())\n')
            model_runner = str(runner)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   TAKIBI_LAND_CONTROL_ROOT=str(root), TAKIBI_LAND_CONTROL_FAIL=fail,
                   TAKIBI_LAND_CONTROL_EQUAL='1' if equal else '',
                   TAKIBI_LAND_CONTROL_MODEL=model_runner, TAKIBI_LAND_CONTROL_PYTHON=sys.executable)
        result = subprocess.run(['bash', str(root / 'scripts/land.sh')],
                                env=env, capture_output=True, text=True)
        trace = [line.split('\t') for line in (root / 'trace.tsv').read_text().splitlines()]
        log = root / '.git/takibi-land' / ('allcheck-' + '1' * 40 + '.log')
        return result.returncode, result.stdout + result.stderr, trace, log.read_text() if log.exists() else ''


def verify(source):
    lanes = ('langcheck', 'test', 'linuxcheck')
    cases = 0
    for position, lane in enumerate(lanes):
        status, output, trace, log = run_case(source, fail=lane)
        assert status == 1, (lane, status, output)
        assert 'land: FAIL precheck ' + lane in output, (lane, output)
        assert 'fixture diagnostic: ' + lane in log, (lane, log)
        assert [call[1] for call in trace if call[0] == 'make'] == list(lanes[:position + 1]), trace
        assert not any(call[:2] == ['git', 'push'] for call in trace), trace
        cases += 1
    status, output, trace, log = run_case(source)
    assert status == 0, output
    assert [call[1] for call in trace if call[0] == 'make'] == [*lanes, 'clean', 'allcheck'], trace
    assert ['git', 'push', 'origin', '1' * 40 + ':refs/heads/main'] in trace, trace
    assert all('fixture pass: ' + lane in log for lane in (*lanes, 'clean', 'allcheck')), log
    cases += 1
    status, output, trace, log = run_case(source, fail='clean')
    assert status == 1 and 'land: FAIL clean' in output, output
    assert [call[1] for call in trace if call[0] == 'make'] == [*lanes, 'clean'], trace
    assert not any(call[:2] == ['git', 'push'] for call in trace), trace
    cases += 1
    status, output, trace, log = run_case(source, fail='allcheck')
    assert status == 1 and 'land: FAIL allcheck' in output, output
    assert not any(call[:2] == ['git', 'push'] for call in trace), trace
    cases += 1
    status, output, trace, log = run_case(source, equal=True)
    assert status == 0 and 'nothing to push' in output, output
    assert not any(call[0] == 'make' for call in trace), trace
    cases += 1
    # A real maintained check, with an actually stale review stamp, must be
    # reported as the first quick lane failure before any long operation.
    status, output, trace, log = run_case(source, real_model=True)
    assert status == 1 and 'land: FAIL precheck langcheck' in output, output
    assert 'FAIL model-function-map' in log and '000000000000' in log, log
    assert [call[1] for call in trace if call[0] == 'make'] == ['langcheck'], trace
    assert not any(call[:2] == ['git', 'push'] for call in trace), trace
    cases += 1
    return cases


def main():
    source = (Path(__file__).resolve().parents[1] / 'scripts/land.sh').read_text()
    cases = CaseCount()
    total = verify(source)
    # The checker must itself notice a reverted quick gate or a swallowed
    # failing make status. Both mutations preserve the rest of the real shell.
    mutants = [source.replace('for lane in langcheck test linuxcheck;', 'for lane in test linuxcheck;', 1),
               source.replace('status=${PIPESTATUS[0]}', 'status=0', 1)]
    for mutant in mutants:
        cases.note()
        try:
            verify(mutant)
        except AssertionError:
            continue
        raise AssertionError('broken precheck control was accepted')
    report_pass('land-precheck-controls',
                f'{total} publication traces and {cases.ran} broken-gate refusals; failures name the lane, skip clean/allcheck/push, and green retains the clean aggregate',
                cases=total + cases.ran)


if __name__ == '__main__':
    main()
