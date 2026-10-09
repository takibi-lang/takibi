#!/usr/bin/env python3
"""Reject direct wall-clock rendezvous loops in maintained boot probes.

Discover every while condition in contention evidence, occupancy evidence,
and the FD refcount probe functions, including helper-based waits. Only the
six reviewed deliberate wall-clock holds below remain. This source check
catches the observed direct counter/deadline shape; it does not prove a
predicate or discover a clock hidden behind an arbitrary external callee.
"""

import re
import sys
from pathlib import Path

from check_model_function_map import function_body, masked_sources
from pass_line import report_pass

HOLDS = {
    'console_ddb_peer_hold': 'external UART BREAK while the lock masks IRQs',
    'ext2_mutation_probe_reader': 'linger to expose missing reader exclusion',
    'ext2_mutation_probe_core0_reader': 'linger to expose missing reader exclusion',
    'signal_probe_hold_locked': 'short collision hold under the IRQ-masking run lock',
    'world_stop_probe': 'stopped peer must take no ticks during a real interval',
    'schedule_contention_probe': 'whole-phase collision retry budget',
}
DEFINITION = re.compile(r'^(?:private\s+)?(?:inline\s+|noinline\s+)?fn\s+(\w+)\s*\(', re.M)


def sources():
    paths = sorted(Path('kernel/kernel').glob('*_contention_evidence.tkb'))
    paths += [Path('kernel/kernel/occupancy_drain_evidence.tkb'),
              Path('kernel/kernel/fd_table.tkb'),
              Path('kernel/lib/peer_tick_window.tkb')]
    return {str(path): path.read_text(encoding='ascii') for path in paths}


def conditions(source):
    code = masked_sources(source)
    for match in re.finditer(r'\bwhile\s*\(', code):
        start = match.end()
        position, depth = start, 1
        while position < len(code) and depth:
            depth += (code[position] == '(') - (code[position] == ')')
            position += 1
        if depth:
            raise ValueError('unclosed while condition')
        yield code[start:position - 1]


def main(tree=None):
    errors, seen, waits = [], {}, 0
    for path, source in (sources() if tree is None else tree).items():
        if path.endswith('/peer_tick_window.tkb'):
            body = function_body('peer_tick_window_open', source)
            if body is None or not re.search(
                    r'kernel_tick_count_of\s*\(window\.peer\)\s*-\s*'
                    r'window\.ticks_start\.value\s*<\s*window\.tick_budget\.ticks',
                    masked_sources(body)):
                errors.append(f'{path}: shared window lost its peer-tick bound')
            continue
        for name in DEFINITION.findall(masked_sources(source)):
            if path.endswith('/fd_table.tkb') and not name.startswith('fd_refcount_'):
                continue
            body = function_body(name, source)
            if body is None:
                errors.append(f'{path}: cannot find {name}')
                continue
            for condition in conditions(body):
                waits += 1
                if (re.search(r'\bread_cntpct\s*\(', condition) or
                        (name == 'world_stop_probe' and
                         re.search(r'\bwall_hold_open\s*\(', condition))):
                    if name not in HOLDS:
                        errors.append(f'{path}: {name}: wall-clock-only probe wait; '
                                      'use a PeerTickWindow for rendezvous')
                    else:
                        seen[name] = seen.get(name, 0) + 1
                        if 'Deliberate' not in body:
                            errors.append(f'{path}: {name}: deliberate hold needs its reason')
    for name in HOLDS:
        if seen.get(name, 0) != 1:
            errors.append(f'{name}: expected one reviewed deliberate wall-clock hold, '
                          f'found {seen.get(name, 0)}')
    if errors:
        for error in errors:
            print(f'ERROR probe-tick-windows: {error}')
        return 1
    report_pass('probe-tick-windows',
                'direct wall-clock probe waits are only reviewed deliberate holds',
                loops=waits, holds=len(seen))
    return 0


if __name__ == '__main__':
    sys.exit(main())
