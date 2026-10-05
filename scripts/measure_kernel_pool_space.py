#!/usr/bin/env python3
"""Validate bounded-boot pool samples and print an allocation accounting TSV.

Consumes a UART capture, not a live target. Slot occupancy includes allocator
states retained by pins; payload is object storage, not bytes used by callers.
"""

import argparse
import re
import sys
from pathlib import Path

POOLS = {'process', 'tcp', 'retx', 'frame', 'backing', 'image',
         'fd_context', 'fd_block', 'object'}
FIELDS = ('object', 'pool', 'slot', 'chunk', 'chunks', 'capacity', 'nonfree', 'bytes')
ROW = re.compile(r'pool space: name=(\w+)' + ''.join(
    rf' {field}=(\d+)' for field in FIELDS))


def parse_capture(text):
    """Require two complete, ordered samples and verify the allocator layout."""
    samples = {}
    phase = None
    for line in text.splitlines():
        # Timestamped dmesg replays are copies, not another observation.
        if not line.startswith('pool space:'):
            continue
        line = line.strip()
        if line.startswith('pool space: begin='):
            name = line.removeprefix('pool space: begin=')
            if phase is not None or name in samples or name not in ('boot', 'bounded_end'):
                raise ValueError('duplicate, unknown, or nested phase')
            phase = name
            samples[phase] = {}
        elif line.startswith('pool space: end='):
            if phase is None or line != f'pool space: end={phase}':
                raise ValueError('mismatched phase end')
            if set(samples[phase]) != POOLS:
                raise ValueError('phase must contain all nine production pools')
            phase = None
        else:
            match = ROW.fullmatch(line)
            if match is None or phase is None:
                raise ValueError('malformed or unframed pool sample')
            name = match[1]
            if name not in POOLS or name in samples[phase]:
                raise ValueError('unknown or duplicate pool')
            data = dict(zip(FIELDS, map(int, match.groups()[1:])))
            validate_layout(name, data)
            samples[phase][name] = data
    if phase is not None or list(samples) != ['boot', 'bounded_end']:
        raise ValueError('capture needs complete boot and bounded_end phases in order')
    for name in POOLS:
        if any(samples['boot'][name][key] != samples['bounded_end'][name][key]
               for key in ('object', 'pool', 'slot', 'chunk')):
            raise ValueError('pool layout changed between phases')
    return samples


def validate_layout(name, data):
    obj, pool, stride, chunk, chunks, capacity, live, size = (data[k] for k in FIELDS)
    if obj == 0 or chunk == 0 or live > capacity or size != chunks * chunk:
        raise ValueError('invalid object size, occupancy, or allocated chunk bytes')
    if name == 'process':
        # Current intrusive layout: one generation word per slot, 128-byte
        # header reservation at the tail, adaptive power-of-two page runs.
        if pool != 104 or stride != obj + 8 or chunk not in (4096, 8192, 16384, 32768):
            raise ValueError('unexpected intrusive pool layout')
        slots = (chunk - 128) // stride
        if slots < 8 and chunk != 32768:
            raise ValueError('intrusive chunk should fit eight slots or reach the cap')
    else:
        # Built-in region layout: 24-byte header, eight-byte state words,
        # payload aligned to 16, and the current conservative 48-byte bound.
        if pool != 16 or stride != obj or chunk % 4096:
            raise ValueError('unexpected built-in region pool layout')
        slots = (chunk - 48) // (obj + 8)
    if slots <= 0 or capacity != chunks * slots:
        raise ValueError('slot capacity disagrees with chunk layout')


def accounting(name, data):
    obj, pool, stride, chunk, chunks, capacity, live, size = (data[k] for k in FIELDS)
    per_chunk = (chunk - 128) // stride if name == 'process' else (chunk - 48) // (obj + 8)
    metadata = capacity * 8
    if name == 'process':
        header = chunks * 128
        padding = 0
        tail = chunks * (chunk - 128 - per_chunk * stride)
    else:
        header = chunks * 24
        payload_start = (24 + per_chunk * 8 + 15) // 16 * 16
        padding = chunks * (payload_start - 24 - per_chunk * 8)
        tail = chunks * (chunk - payload_start - per_chunk * obj)
    occupied = live * obj
    free = (capacity - live) * obj
    if min(header, padding, tail) < 0 or size != occupied + free + metadata + header + padding + tail:
        raise ValueError('allocation accounting does not sum to chunk bytes')
    return (occupied, free, metadata, header, padding, tail, pool + size)


def render_tsv(samples):
    lines = ['phase\tname\t' + '\t'.join(FIELDS) +
             '\toccupied_storage\tfree_storage\tslot_metadata\theader_reserved\talignment\ttail\ttotal']
    for phase, rows in samples.items():
        for name in sorted(rows):
            data = rows[name]
            values = tuple(data[k] for k in FIELDS) + accounting(name, data)
            lines.append(f'{phase}\t{name}\t' + '\t'.join(map(str, values)))
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    args = parser.parse_args()
    try:
        print(render_tsv(parse_capture(args.capture.read_text(errors='replace'))), end='')
    except ValueError as error:
        parser.exit(1, f'pool-space measurement: {error}\n')


if __name__ == '__main__':
    main()
