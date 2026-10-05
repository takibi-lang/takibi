#!/usr/bin/env python3
"""Check capture rejection and allocation accounting using in-memory controls."""
import sys
sys.dont_write_bytecode = True
from measure_kernel_pool_space import POOLS, accounting, parse_capture, render_tsv
from pass_line import CaseCount, report_pass


def capture():
    lines = []
    for phase in ('boot', 'bounded_end'):
        lines.append(f'pool space: begin={phase}')
        for name in sorted(POOLS):
            if name == 'process':
                row = 'object=872 pool=104 slot=880 chunk=8192 chunks=1 capacity=9 nonfree=1 bytes=8192'
            else:
                row = 'object=40 pool=16 slot=40 chunk=4096 chunks=1 capacity=84 nonfree=1 bytes=4096'
            lines.append(f'pool space: name={name} {row}')
        lines.append(f'pool space: end={phase}')
    return '\n'.join(lines) + '\n'


def main():
    text = capture()
    samples = parse_capture(text)
    assert accounting('backing', samples['boot']['backing']) == (40, 3320, 672, 24, 8, 32, 4112)
    assert accounting('process', samples['boot']['process']) == (872, 6976, 72, 128, 0, 144, 8296)
    assert len(render_tsv(samples).splitlines()) == 19
    # Retained-log replays must not double-count allocator observations.
    assert parse_capture(text + '[0.123] pool space: begin=boot\n') == samples
    empty = text.replace('chunks=1 capacity=84 nonfree=1 bytes=4096',
                         'chunks=0 capacity=0 nonfree=0 bytes=0')
    assert accounting('backing', parse_capture(empty)['boot']['backing']) == (0, 0, 0, 0, 0, 0, 16)
    # Preserve archived 16-byte captures, and account for the adopted durable
    # generation counter without accepting arbitrary body sizes.
    durable = parse_capture(text.replace('pool=16', 'pool=24'))
    assert accounting('backing', durable['boot']['backing'])[-1] == 4120
    controls = [
        text.replace('pool=16', 'pool=32', 1),
        text.replace(' nonfree=1 bytes=4096', ' nonfree=85 bytes=4096', 1),
        text.replace('capacity=84', 'capacity=83', 1),
        text.replace('bytes=4096', 'bytes=4095', 1),
        text.replace('end=boot', 'end=bounded_end', 1),
        text.replace('name=backing', 'name=tcp', 1),
        text.replace('name=backing', 'name=unknown', 1),
        text.replace('pool space: name=backing', 'missing: name=backing', 1),
        text.replace('slot=40', 'slot=41', 1),
        text.replace('pool=104', 'pool=80', 1),
        text.replace('end=bounded_end\n', '', 1),
        text.replace('begin=boot', 'begin=unknown', 1),
        '',
    ]
    cases = CaseCount()
    for bad in controls:
        cases.note()
        try:
            parse_capture(bad)
        except ValueError:
            continue
        raise AssertionError('malformed capture was accepted')
    report_pass('pool-space-controls',
                f'allocation identities, empty pools, replay, and {cases.ran} rejection controls',
                cases=cases.ran)


if __name__ == '__main__':
    main()
