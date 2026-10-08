#!/usr/bin/env python3
"""Exercise the actual previous freelist body and probe-entry discovery."""

import contextlib
import io

import check_probe_round_restart as checker
from build_qemu_race_window import WINDOWS
from pass_line import CaseCount, report_pass


def check(sources, expected, diagnostic=None):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        status = checker.main(sources)
    assert status == expected, output.getvalue()
    if diagnostic is not None:
        assert diagnostic in output.getvalue(), output.getvalue()


def main():
    cases = CaseCount()
    sources = checker.tracked_sources()
    check(sources, 0)
    cases.note()
    path, corrected, previous = WINDOWS['678']['check']
    path = 'kernel/' + path
    assert sources[path].count(corrected) == 1
    old = sources[path].replace(corrected, previous)
    for source in (old, old.replace('for round:', 'for iteration:').replace(
            'false, round + 1', 'false, iteration + 1')):
        check({**sources, path: source}, 1,
              'freelist_contention_secondary_run: invocation-local round batch restarts')
        cases.note()
    for qualifier in ('inline ', 'noinline ', 'private inline ', 'private noinline '):
        renamed = old.replace('fn freelist_contention_secondary_run(',
                              qualifier + 'fn freelist_contention_secondary_run(')
        check({**sources, path: renamed}, 1, 'invocation-local round batch restarts')
        cases.note()
    harmless = sources[path].replace(corrected, corrected +
        '// for round: usize in 0..<FAKE_ROUNDS {}\n'
        '/* for round: usize in 0..<FAKE_ROUNDS {} */\n'
        '    let ignored: *u8 = "for round: usize in 0..<FAKE_ROUNDS {}" as *u8;\n')
    check({**sources, path: harmless}, 0)
    cases.note()
    # Entry discovery must cover a new name, not only a fixed freelist list.
    extra = {**sources, checker.DRIVER: sources[checker.DRIVER] +
             '\nfn extra_dispatch() { fresh_secondary_run(); }\n',
             'kernel/kernel/fresh.tkb':
             'fn fresh_secondary_run() { for work: usize in 0..<FRESH_ROUNDS {} }\n'}
    check(extra, 1, 'fresh_secondary_run: invocation-local round batch restarts')
    cases.note()
    del extra['kernel/kernel/fresh.tkb']
    check(extra, 1, 'fresh_secondary_run: expected one maintained body, found 0')
    cases.note()
    duplicate = {**sources, 'kernel/kernel/duplicate.tkb': old}
    check(duplicate, 1, 'freelist_contention_secondary_run: expected one maintained body, found 2')
    cases.note()
    check({**sources, checker.DRIVER: '// no probe entries\n'}, 1,
          'no secondary probe entries found')
    cases.note()
    # Document the real strength: unrelated fixed-size buffer loops are allowed.
    local_buffer = sources[path].replace(corrected, corrected +
        '    for byte: usize in 0..<8 {}\n')
    check({**sources, path: local_buffer}, 0)
    cases.note()
    report_pass('probe-round-restart controls',
                'actual old loop and renamed/qualified copies fail by name; '
                'entry discovery refuses missing/duplicate bodies; comments, strings and buffer loops pass',
                cases=cases.ran)


if __name__ == '__main__':
    main()
