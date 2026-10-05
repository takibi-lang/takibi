#!/usr/bin/env python3
"""Exercise the milestone review gate without Git, a board, or a wait."""
import copy
from pathlib import Path
import sys
sys.dont_write_bytecode = True
from space_checkpoint import REVIEW, production_source, source_digest, validate_review
from pass_line import CaseCount, report_pass


def main():
    entries = {'kernel/kernel/fd_table.tkb': '1' * 40,
               'lib/region_builtin.ml': '2' * 40,
               'docs/result.tsv': '3' * 40, REVIEW: '5' * 40}
    digest = source_digest(entries)
    good = dict(date='2026-10-05', event='milestone', decision='measured',
                source_sha256=digest, workload='open/fork/close live and teardown',
                evidence=['docs/result.tsv'], assessment='payload shrinks; pages unchanged',
                next_trigger='completion of a new kernel resource or lifetime')
    validate_review(good, digest, entries)
    reuse = dict(good, event='incremental', decision='reuse')
    validate_review(reuse, digest, entries)
    # Documentation does not stale the source review; implementation does.
    assert source_digest(dict(entries, **{'docs/new.md': '4' * 40})) == digest
    assert source_digest(dict(entries, **{'kernel/kernel/fd_table.tkb': '4' * 40})) != digest
    deleted = dict(entries)
    del deleted['lib/region_builtin.ml']
    assert source_digest(deleted) != digest
    assert production_source('kernel/arch/arm64/boot/link.ld')
    assert production_source('kernel/tests/user/program.c')
    assert production_source('Makefile')
    assert not production_source('kernel/benchmarks/service_space/workload.c')
    assert not production_source('docs/result.tsv')
    bad = []
    for key in good:
        item = copy.deepcopy(good)
        del item[key]
        bad.append(item)
    for key, value in [('extra', True), ('source_sha256', '0' * 64),
                       ('event', 'later'), ('decision', 'defer'),
                       ('decision', 'reuse'), ('date', '2026-02-30'),
                       ('date', '2026-1-1'), ('assessment', ''),
                       ('workload', ''), ('next_trigger', ''),
                       ('evidence', []), ('evidence', ['docs/missing.tsv']),
                       ('evidence', ['../result.tsv']), ('evidence', [3]),
                       ('evidence', 'docs/result.tsv'), ('evidence', [REVIEW])]:
        item = copy.deepcopy(good)
        item[key] = value
        bad.append(item)
    cases = CaseCount()
    for item in bad:
        cases.note()
        try:
            validate_review(item, digest, entries)
        except ValueError:
            continue
        raise AssertionError(f'invalid checkpoint accepted: {item}')
    cases.note()
    try:
        validate_review(good, digest, dict(entries, **{
            'docs/result.tsv': 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'}))
    except ValueError:
        pass
    else:
        raise AssertionError('empty evidence accepted')
    root = Path(__file__).resolve().parents[1]
    land = (root / 'scripts/land.sh').read_text()
    hook = 'python3 scripts/space_checkpoint.py --base origin/main --head "$tested"'
    assert hook in land
    assert land.index('git pull --rebase') < land.index(hook) < land.index('make clean >')
    assert 'exit 2' in land[land.index(hook):land.index('log_dir=')]
    report_pass('space-checkpoint-controls',
                f'milestone/reuse, source binding, deletion, publication hook and {cases.ran} refusal cases',
                cases=cases.ran)


if __name__ == '__main__':
    main()
