#!/usr/bin/env python3
"""Run the real publication shell with deterministic local command providers.

No Git repository, network, board, suite lease or actual build is touched.
The trace verifies which make/git operations the shell really requests.
"""
from control_patch import replace_once
import os
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
            if [ "$1" = allcheck ]; then
                # A failing lane's capture, as a runner leaves it (#875).
                mkdir -p "$TAKIBI_LAND_CONTROL_ROOT/_build/kernel-fixture-lane"
                printf 'failing uart\n' > "$TAKIBI_LAND_CONTROL_ROOT/_build/kernel-fixture-lane/uart.log"
                printf 'image\n' > "$TAKIBI_LAND_CONTROL_ROOT/_build/kernel-fixture-lane/ext2.img"
            fi
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
            "diff --no-renames --name-only origin/main 1111111111111111111111111111111111111111")
                printf '%b' "$TAKIBI_LAND_CONTROL_DIFF" ;;
            pull*|fetch*|push*|merge-base*) : ;;
            *) printf 'unexpected git command: %s\n' "$*" >&2; exit 42 ;;
        esac
        ;;
    *) printf 'unexpected provider: %s\n' "$command" >&2; exit 42 ;;
esac
'''


def run_case(source, fail='', equal=False, real_model=False, diff='compiler/main.ml\n'):
    with tempfile.TemporaryDirectory(prefix='takibi-land-precheck-') as tmp:
        root = Path(tmp)
        (root / 'scripts').mkdir()
        (root / 'scripts/land.sh').write_text(source)
        repo_scripts = Path(__file__).resolve().parent
        (root / 'scripts/land_light_paths').write_text((repo_scripts / 'land_light_paths').read_text())
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        for name in ('git', 'make', 'python3'):
            script = bin_dir / name
            script.write_text(PROVIDER)
            script.chmod(0o755)
        model_runner = ''
        if real_model:
            # A real langcheck member with a stale input. It was the model
            # map until GitHub issue #987 moved that check to the kernel
            # build, where it reads the compiler's call-graph tables.
            repo = Path(__file__).resolve().parents[1]
            table = (repo / 'docs/KNOWN_INTERMITTENTS.md').read_text()
            (root / 'stale-readme.md').write_text(table + '| zz-stale-row |\n')
            runner = root / 'real-model-check.py'
            runner.write_text('import sys, pathlib\n'
                              'sys.dont_write_bytecode = True\n'
                              'sys.path.insert(0, ' + repr(str(repo / 'scripts')) + ')\n'
                              'import check_known_intermittents as check\n'
                              'check.TABLE = pathlib.Path(sys.argv[1])\n'
                              'raise SystemExit(check.main())\n')
            model_runner = str(runner)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   TAKIBI_LAND_CONTROL_ROOT=str(root), TAKIBI_LAND_CONTROL_FAIL=fail,
                   TAKIBI_LAND_CONTROL_EQUAL='1' if equal else '',
                   TAKIBI_LAND_CONTROL_DIFF=diff,
                   TAKIBI_LAND_CONTROL_MODEL=model_runner, TAKIBI_LAND_CONTROL_PYTHON=sys.executable)
        result = subprocess.run(['bash', str(root / 'scripts/land.sh')],
                                env=env, capture_output=True, text=True)
        trace = [line.split('\t') for line in (root / 'trace.tsv').read_text().splitlines()]
        log = root / '.git/takibi-land' / ('allcheck-' + '1' * 40 + '.log')
        kept_dir = root / '.git/takibi-land' / ('1' * 40)
        kept = sorted(str(path.relative_to(kept_dir)) for path in kept_dir.rglob('*')
                      if path.is_file()) if kept_dir.is_dir() else []
        return (result.returncode, result.stdout + result.stderr, trace,
                log.read_text() if log.exists() else '', kept)


def verify(source):
    lanes = ('langcheck', 'test', 'linuxcheck')
    cases = 0
    for position, lane in enumerate(lanes):
        status, output, trace, log, kept = run_case(source, fail=lane)
        assert status == 1, (lane, status, output)
        assert 'land: FAIL precheck ' + lane in output, (lane, output)
        assert 'fixture diagnostic: ' + lane in log, (lane, log)
        assert [call[1] for call in trace if call[0] == 'make'] == list(lanes[:position + 1]), trace
        assert not any(call[:2] == ['git', 'push'] for call in trace), trace
        cases += 1
    status, output, trace, log, kept = run_case(source)
    assert status == 0, output
    assert [call[1] for call in trace if call[0] == 'make'] == [*lanes, 'clean', 'allcheck'], trace
    assert ['git', 'push', 'origin', '1' * 40 + ':refs/heads/main'] in trace, trace
    # The rebase goes through the checkpoint-conflict resolver (#832), before
    # the space gate, which therefore checks the re-recorded review.
    rebase = ['python3', 'scripts/checkpoint_rebase.py', '--onto', 'origin/main']
    assert rebase in trace and not any(call[:2] == ['git', 'pull'] for call in trace), trace
    assert trace.index(rebase) < next(i for i, call in enumerate(trace)
                                      if call[:2] == ['python3', 'scripts/space_checkpoint.py']), trace
    assert all('fixture pass: ' + lane in log for lane in (*lanes, 'clean', 'allcheck')), log
    cases += 1
    status, output, trace, log, kept = run_case(source, fail='clean')
    assert status == 1 and 'land: FAIL clean' in output, output
    assert [call[1] for call in trace if call[0] == 'make'] == [*lanes, 'clean'], trace
    assert not any(call[:2] == ['git', 'push'] for call in trace), trace
    cases += 1
    status, output, trace, log, kept = run_case(source, fail='allcheck')
    assert status == 1 and 'land: FAIL allcheck' in output, output
    assert not any(call[:2] == ['git', 'push'] for call in trace), trace
    # GitHub issue #875: the failed run's lane captures survive a rerun,
    # under the tested commit, without the disk image.
    assert kept == ['kernel-fixture-lane/uart.log'], kept
    assert 'land: kept 1 lane capture(s)' in output, output
    cases += 1
    status, output, trace, log, kept = run_case(source, equal=True)
    assert status == 0 and 'nothing to push' in output, output
    assert not any(call[0] == 'make' for call in trace), trace
    cases += 1
    # A real maintained check, with an actually stale review stamp, must be
    # reported as the first quick lane failure before any long operation.
    status, output, trace, log, kept = run_case(source, real_model=True)
    assert status == 1 and 'land: FAIL precheck langcheck' in output, output
    assert 'FAIL known-intermittents' in log and 'zz-stale-row' in log, log
    assert [call[1] for call in trace if call[0] == 'make'] == ['langcheck'], trace
    assert not any(call[:2] == ['git', 'push'] for call in trace), trace
    cases += 1
    # Light route: only listed paths changed, so langcheck alone gates the
    # push. One unlisted path -- a contract document at the root, or anything
    # under docs/ -- takes the full route.
    status, output, trace, log, kept = run_case(source, diff='ROADMAP.md\n.github/workflows/ci.yml\n')
    assert status == 0, output
    assert [call[1] for call in trace if call[0] == 'make'] == ['langcheck'], trace
    assert ['git', 'push', 'origin', '1' * 40 + ':refs/heads/main'] in trace, trace
    cases += 1
    status, output, trace, log, kept = run_case(source, diff='ROADMAP.md\n', fail='langcheck')
    assert status == 1 and 'land: FAIL light langcheck' in output, output
    assert not any(call[:2] == ['git', 'push'] for call in trace), trace
    cases += 1
    for diff in ('ROADMAP.md\nEFFECTS.md\n', 'docs/ROADMAP.md\n', 'README.md.orig\n', ''):
        status, output, trace, log, kept = run_case(source, diff=diff)
        assert status == 0, (diff, output)
        assert [call[1] for call in trace if call[0] == 'make'] == [*lanes, 'clean', 'allcheck'], (diff, trace)
        cases += 1
    return cases


def main():
    source = (Path(__file__).resolve().parents[1] / 'scripts/land.sh').read_text()
    cases = CaseCount()
    total = verify(source)
    # The checker must itself notice a reverted quick gate, a swallowed
    # failing make status, or a light-path match that accepts anything. Each
    # mutation preserves the rest of the real shell.
    mutants = [replace_once(source, 'for lane in langcheck test linuxcheck;', 'for lane in test linuxcheck;'),
               # GitHub issue #845: the light path's status, named by the
               # make line above it, since replace_once refuses a repeat.
               replace_once(source, 'make langcheck 2>&1 | tee -a "$log"\n    status=${PIPESTATUS[0]}',
                            'make langcheck 2>&1 | tee -a "$log"\n    status=0'),
               replace_once(source, '[ "$path" = "$entry" ] && listed=1', 'listed=1'),
               # #875: a failed allcheck that forgets its captures.
               replace_once(source, '        keep_failed_captures\n', '\n')]
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
