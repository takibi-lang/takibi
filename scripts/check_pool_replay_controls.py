#!/usr/bin/env python3
"""Validate recorded replay evidence and reject incomplete or unequal workloads."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
from measure_pool_replay import parse_capture, render_tsv, workload
from pass_line import CaseCount, report_pass


def main():
    root = Path(__file__).resolve().parent.parent / 'kernel/benchmarks/pool_space'
    captures = {key: (root / 'captures' / (key + '.txt')).read_text() for key in ('takibi', 'slub', 'uma')}
    parsed = {key: parse_capture(value, key) for key, value in captures.items()}
    assert render_tsv(parsed) == (root / 'comparison.tsv').read_text()
    for key, original in parsed.items():
        assert parse_capture((root / 'captures' / (key + '-repeat.txt')).read_text(), key) == original
    assert len(workload()) == 9
    assert len(parsed['takibi']) == len(parsed['slub']) == len(parsed['uma']) == 90
    controls = []
    for key, text in captures.items():
        lines = text.splitlines()
        controls.extend((key, value) for value in (
            '\n'.join(lines[1:]),
            '\n'.join(lines[:-1]),
            '\n'.join(lines[:2] + [lines[1]] + lines[2:]),
            text.replace('live=32', 'live=31', 1),
            text.replace('object=872', 'object=864', 1),
            text.replace('bytes=32768', 'bytes=32767', 1),
            text.replace('count=32', 'count=33', 1),
        ))
    controls.extend([
        ('takibi', captures['takibi'].replace('after teardown=0', 'after teardown=1')),
        ('slub', captures['slub'].replace('module_status=0', 'module_status=1')),
        ('uma', captures['uma'].replace('module_status=0', 'module_status=1')),
        ('uma', captures['uma'].replace('observed_live=32', 'observed_live=31', 1)),
        ('slub', captures['slub'].replace('cpus=2', 'cpus=1', 1)),
        ('uma', captures['uma'].replace('done allocator=uma', 'done allocator=slub')),
    ])
    cases = CaseCount()
    for key, text in controls:
        cases.note()
        try:
            parse_capture(text, key)
        except ValueError:
            continue
        raise AssertionError('invalid replay capture accepted: ' + key)
    report_pass('pool-replay-controls', f'540 samples including repeats, recorded TSV, and {cases.ran} capture rejection controls', cases=cases.ran)


if __name__ == '__main__':
    main()
