#!/usr/bin/env python3
"""Validate equal-workload allocator captures and report charged storage bytes."""
import argparse
import csv
import re
from pathlib import Path
from measure_kernel_pool_space import validate_layout, accounting

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'kernel/benchmarks/pool_space/workload.tsv'
PHASES = ('empty', 'full', 'half', 'refill', 'free')
COMMON = {'name', 'count', 'phase', 'object', 'pool', 'chunks', 'capacity', 'live', 'bytes'}
EXTRA = {
    'takibi': set(),
    'slub': {'cpu', 'nodes', 'random', 'stride', 'order', 'cpus'},
    'uma': {'keg', 'buckets', 'counters', 'hash', 'offpage', 'stride', 'pages_per_chunk', 'cpus', 'flags', 'observed_live'},
}


def workload():
    return list(csv.DictReader(MANIFEST.open(), delimiter='\t'))


def parse_capture(text, allocator):
    expected = [(row, count, phase) for count in (32, 128) for row in workload() for phase in PHASES]
    rows = []
    done = False
    status = False
    for line in text.splitlines():
        line = re.sub(r'^\[\s*[\d.]+\]\s*', '', line.strip())
        if line.startswith('pool replay: module_status='):
            line = line.removeprefix('pool replay: ')
        if line.startswith('pool replay: done'):
            if allocator == 'takibi' or done or line != f'pool replay: done allocator={allocator}' or len(rows) != len(expected):
                raise ValueError('missing, duplicate, or premature completion')
            done = True
        elif line.startswith('pool replay:'):
            if done or len(rows) >= len(expected):
                raise ValueError('duplicate or trailing sample')
            pairs = [token.split('=') for token in line.removeprefix('pool replay: ').split()]
            if any(len(pair) != 2 for pair in pairs):
                raise ValueError('malformed sample')
            data = dict(pairs)
            if len(data) != len(pairs) or set(data) != COMMON | EXTRA[allocator]:
                raise ValueError('duplicate, missing, or unknown field')
            manifest, count, phase = expected[len(rows)]
            if data['name'] != manifest['name'] or data['phase'] != phase:
                raise ValueError('sample order differs from the common workload')
            for key in set(data) - {'name', 'phase'}:
                if not data[key].isdigit():
                    raise ValueError('non-numeric or negative sample')
                data[key] = int(data[key])
            live = {'empty': 0, 'full': count, 'half': count // 2, 'refill': count, 'free': 0}[phase]
            if data['count'] != count or data['object'] != int(manifest['object_bytes']) or data['live'] != live or data['capacity'] < live:
                raise ValueError('sample does not match the common object size/count/lifetime')
            if allocator == 'takibi':
                chunk = int(manifest['chunk_pages']) * 4096
                layout = dict(object=data['object'], pool=data['pool'], slot=data['object'] + (8 if data['name'] == 'process' else 0),
                              chunk=chunk, chunks=data['chunks'], capacity=data['capacity'], nonfree=live, bytes=data['bytes'])
                validate_layout(data['name'], layout)
                accounting(data['name'], layout)
                aux = data['pool']
            else:
                if data['cpus'] != 2 or data['stride'] < data['object'] or data['stride'] % 8:
                    raise ValueError('unexpected guest CPU count or object stride')
                if allocator == 'slub':
                    if data['order'] > 3:
                        raise ValueError('unexpected SLUB slab order')
                    chunk = 4096 << data['order']
                    # No order fallback or debug/redzone layout in this capture.
                    if data['capacity'] != data['chunks'] * (chunk // data['stride']):
                        raise ValueError('SLUB capacity disagrees with observed slab layout')
                    aux = sum(data[key] for key in ('pool', 'cpu', 'nodes', 'random'))
                else:
                    chunk = 4096 * data['pages_per_chunk']
                    if chunk == 0 or data['observed_live'] != live or (data['chunks'] == 0) != (data['capacity'] == 0):
                        raise ValueError('UMA live counter or chunk layout disagrees')
                    if data['chunks'] and (data['capacity'] % data['chunks'] or data['capacity'] // data['chunks'] * data['stride'] > chunk):
                        raise ValueError('UMA capacity exceeds its observed slab storage')
                    aux = sum(data[key] for key in ('pool', 'keg', 'buckets', 'counters', 'hash', 'offpage'))
                if data['bytes'] != data['chunks'] * chunk:
                    raise ValueError('allocated bytes disagree with chunk count')
            data['aux_bytes'] = aux
            data['charged_bytes'] = data['bytes'] + aux
            rows.append(data)
        elif line.startswith('module_status='):
            if allocator == 'takibi' or not done or status or line != 'module_status=0':
                raise ValueError('guest module did not complete successfully')
            status = True
        elif line.startswith('replay provider pages after teardown='):
            if allocator != 'takibi' or status or len(rows) != len(expected) or line != 'replay provider pages after teardown=0':
                raise ValueError('Takibi page provider did not return to zero')
            done = status = True
    if len(rows) != len(expected) or not done or not status:
        raise ValueError('capture is incomplete or lacks successful teardown')
    return rows


def render_tsv(captures):
    fields = ('count', 'name', 'phase', 'object', 'chunks', 'capacity', 'live', 'bytes', 'aux_bytes', 'charged_bytes')
    lines = ['allocator\t' + '\t'.join(fields)]
    for allocator, rows in captures.items():
        for row in rows:
            lines.append(allocator + '\t' + '\t'.join(str(row[key]) for key in fields))
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for allocator in EXTRA:
        parser.add_argument('--' + allocator, type=Path, required=True)
    args = parser.parse_args()
    try:
        print(render_tsv({key: parse_capture(getattr(args, key).read_text(), key) for key in EXTRA}), end='')
    except ValueError as error:
        parser.exit(1, f'pool replay: {error}\n')


if __name__ == '__main__':
    main()
