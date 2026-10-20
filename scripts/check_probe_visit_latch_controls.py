#!/usr/bin/env python3
"""Controls for check_probe_visit_latch.py: the #853 and #860 shapes reject."""

import contextlib
import io

import check_probe_visit_latch as checker
from control_patch import replace_once
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
    occupancy = 'kernel/kernel/occupancy_drain_evidence.tkb'
    # The #853 shape: armed for every peer alike.
    check({**tree, occupancy: replace_once(
        tree[occupancy],
        ' &&\n           peer_tally_count(&occupancy_probe_tally, cpu) == 0;',
        ';')}, 1, 'occupancy_drain_is_armed: armed for every peer alike')
    cases.note()
    asid = 'kernel/kernel/asid_contention_evidence.tkb'
    check({**tree, asid: replace_once(
        tree[asid],
        ' &&\n           peer_tally_count(&asid_probe_tally, cpu) < '
        'ASID_CONTENTION_ROUNDS;', ';')}, 1,
        'asid_contention_is_armed: armed for every peer alike')
    cases.note()
    idle = checker.IDLE
    check({**tree, idle: replace_once(
        tree[idle], 'occupancy_drain_is_armed(core_id)',
        'occupancy_drain_is_armed(cpu_id())')}, 1, 'pass core_id')
    cases.note()
    # A hold that the idle loop no longer asks is a stale entry.
    check({**tree, idle: replace_once(
        tree[idle],
        '                if (signal_contention_is_armed(core_id)) {\n'
        '                    signal_contention_secondary_run(core_id);\n'
        '                }\n', '')}, 1, 'listed in HOLDS but not asked')
    cases.note()
    # The #756 / #860 aggregate shape: core 0 waits on every writer's count
    # with CPU 1's clock.
    storm = 'kernel/kernel/log_storm_evidence.tkb'
    check({**tree, storm: replace_once(
        tree[storm],
        'let mut window = peer_tick_window_policy(cpu, PeerTickPolicy::Arrival);\n'
        '            while (peer_tick_window_open(window) &&\n'
        '                   atomic_word_load(cell) < value) { }',
        'let mut window = peer_tick_window_policy(\n'
        '                peer_tick_window_peer(), PeerTickPolicy::Arrival);\n'
        '            while (peer_tick_window_open(window) &&\n'
        '                   atomic_word_load(cell) < value) { }')}, 1,
        'log_storm_wait_peers: waits on peer_tick_window_peer()')
    cases.note()
    console = 'kernel/kernel/console_contention_evidence.tkb'
    check({**tree, console: replace_once(
        tree[console],
        '    let mut window = peer_tick_window_policy(\n'
        '        peer_tick_window_peer(), PeerTickPolicy::Arrival);\n'
        '    while (peer_tick_window_open(window)) {\n'
        '        if (atomic_word_load(cell) != 0)',
        '    let mut window = peer_tick_window_policy(\n'
        '        0, PeerTickPolicy::Arrival);\n'
        '    while (peer_tick_window_open(window)) {\n'
        '        if (atomic_word_load(cell) != 0)')}, 1,
        'console_probe_wait: listed in PAIR_WINDOW but no longer calls')
    cases.note()
    fresh = 'kernel/kernel/new_contention_evidence.tkb'
    check({**tree, fresh: '// peer_tick_window_peer() in a comment\n'
           'fn harmless() { let text: *u8 = "peer_tick_window_peer()"; }\n'}, 0)
    cases.note()
    check({**tree, fresh: 'fn fresh_wait() !{unsafe} {\n'
           '    let mut window = peer_tick_window_policy(\n'
           '        peer_tick_window_peer(), PeerTickPolicy::Arrival);\n'
           '    peer_tick_window_end(window);\n}\n'}, 1,
          'fresh_wait: waits on peer_tick_window_peer()')
    cases.note()
    report_pass('probe-visit-latch controls',
                'an arming question without the visit latch, an idle-loop ask '
                'without core_id, stale entries and a new fixed-pair wait '
                'reject; comments and strings pass', cases=cases.ran)


if __name__ == '__main__':
    main()
