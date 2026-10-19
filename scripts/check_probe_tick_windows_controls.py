#!/usr/bin/env python3
"""Mutate real entry and helper waits, retaining intentional timing holds."""

from control_patch import replace_once
import contextlib
import io

import check_probe_tick_windows as checker
from pass_line import CaseCount, report_pass


def check(tree, status, diagnostic=None):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        actual = checker.main(tree)
    assert actual == status, output.getvalue()
    if diagnostic:
        assert diagnostic in output.getvalue(), output.getvalue()


def main():
    tree, cases = checker.sources(), CaseCount()
    check(tree, 0)
    cases.note()
    helper = 'kernel/lib/peer_tick_window.tkb'
    check({**tree, helper: tree[helper].replace(
        'kernel_tick_count_of(window.peer) - window.ticks_start.value <\n'
        '               window.tick_budget.ticks &&', 'true &&')}, 1,
        'shared window lost its peer-tick bound')
    cases.note()
    # GitHub issue #845: `tail` makes a site whose binding repeats in its
    # file unique, since replace_once refuses a repeated anchor.
    for path, name, binding, tail in (
            ('kernel/kernel/freelist_contention_evidence.tkb', 'freelist_contention_phase', 'entry_window', ''),
            ('kernel/kernel/init_once_contention_evidence.tkb', 'init_once_probe_wait_arrived', 'window',
             ' &&\n                   atomic_word_load(&init_once_probe_arrived)'),
            ('kernel/kernel/pool_walk_contention_evidence.tkb', 'pool_walk_contention_probe', 'entry_window', ''),
            ('kernel/kernel/fd_table.tkb', 'fd_refcount_contention_probe', 'entry_window', '')):
        anchor = f'peer_tick_window_open({binding})' + tail
        previous = replace_once(tree[path], anchor,
                                'read_cntpct() - begin < read_cntfrq() >> 2' + tail)
        check({**tree, path: previous}, 1, f'{name}: wall-clock-only probe wait')
        cases.note()
    path = 'kernel/kernel/new_contention_evidence.tkb'
    body = 'fn fresh_wait() { while (read_cntpct() < deadline) {} }\n'
    for source in (body, body.replace('fn ', 'private noinline fn '),
                   body.replace('fresh_wait', 'helper_wait').replace('deadline', 'limit')):
        check({**tree, path: source}, 1, 'wall-clock-only probe wait')
        cases.note()
    check({**tree, path: '// while (read_cntpct() < deadline) {}\n'
           'fn harmless() { let text: *u8 = "while (read_cntpct())"; }'}, 0)
    cases.note()
    held = 'kernel/kernel/signal_contention_evidence.tkb'
    check({**tree, held: replace_once(tree[held], '    let start: i64 = read_cntpct();', '    while (read_cntpct() < another_deadline) {}\n'
          '    let start: i64 = read_cntpct();')}, 1,
          'expected one reviewed deliberate wall-clock hold, found 2')
    cases.note()
    check({**tree, held: tree[held].replace('// Deliberate hold:', '// Hold:')},
          1, 'deliberate hold needs its reason')
    cases.note()
    report_pass('probe-tick-windows controls',
                'old direct gates, helper waits and additional holds reject; '
                'reviewed holds and masked comments/strings pass', cases=cases.ran)


if __name__ == '__main__':
    main()
