#!/usr/bin/env python3
"""Validate retention traces and summarize accounting and bounded wall-time observations."""
import argparse
import re
import statistics
from pathlib import Path

COUNTS = (1, 32, 128)
STATS = {'retain', 'grows', 'shrinks', 'grow_ticks', 'shrink_ticks', 'chunks', 'capacity', 'live', 'bytes', 'frequency'}


def parse(text):
    pools = {}
    timings = []
    state = 'boot'
    retain = frequency = None
    for line in text.splitlines():
        if line.startswith('retention stats: '):
            pieces = [word.split('=') for word in line.removeprefix('retention stats: ').split()]
            row = dict(pieces)
            if len(pieces) != len(row) or set(row) != STATS | {'phase', 'pool'}:
                raise ValueError('malformed pool counters')
            phase, pool = row.pop('phase'), row.pop('pool')
            if phase not in ('boot', 'launch', 'bounded_end') or pool not in ('fd_block', 'object') or (phase, pool) in pools:
                raise ValueError('unknown or duplicate accounting window')
            if (phase in ('boot', 'launch') and state != 'boot') or (phase == 'bounded_end' and state != 'exited'):
                raise ValueError('unframed accounting window')
            if any(not word.isdigit() for word in row.values()):
                raise ValueError('non-numeric pool sample')
            row = {key: int(value) for key, value in row.items()}
            if row['retain'] not in (0, 1) or row['frequency'] <= 0:
                raise ValueError('unsupported policy or clock')
            if retain is not None and (row['retain'], row['frequency']) != (retain, frequency):
                raise ValueError('policy or frequency changed')
            retain, frequency = row['retain'], row['frequency']
            slots = 9 if pool == 'fd_block' else 46
            if row['capacity'] != slots*row['chunks'] or row['bytes'] != 4096*row['chunks'] or row['live'] > row['capacity']:
                raise ValueError('pool reservation mismatch')
            if row['chunks'] != row['grows']-row['shrinks']:
                raise ValueError('cumulative allocation accounting mismatch')
            pools[phase, pool] = row
        elif line == 'retention workload: begin':
            if state != 'boot' or len(pools) != 4:
                raise ValueError('missing baseline or duplicate workload')
            state = 'running'
        elif line.startswith('retention workload: count='):
            match = re.fullmatch(r'retention workload: count=(\d+) batch=(\d+) rounds=16 ns=(\d+)', line)
            if not match or state != 'running' or len(timings) >= 21:
                raise ValueError('malformed or unframed timing batch')
            count, batch, ns = map(int, match.groups())
            if (count, batch) != (COUNTS[len(timings)//7], len(timings)%7) or ns <= 0:
                raise ValueError('incomplete or unequal workload')
            timings.append({'count': count, 'batch': batch, 'ns': ns})
        elif line == 'retention workload: done':
            if state != 'running' or len(timings) != 21:
                raise ValueError('premature completion')
            state = 'done'
        elif line == 'retention workload: status=0':
            if state != 'done': raise ValueError('invalid exit')
            state = 'exited'
        elif line == 'retention workload: teardown':
            if state != 'exited' or len(pools) != 6: raise ValueError('missing teardown samples')
            state = 'finished'
        else:
            raise ValueError('unexpected or failed output')
    if state != 'finished': raise ValueError('incomplete capture')
    result = {'retain': retain, 'frequency': frequency, 'timings': timings, 'pools': {}}
    for pool in ('fd_block', 'object'):
        boot, before, after = pools['boot', pool], pools['launch', pool], pools['bounded_end', pool]
        if any(before[key] < boot[key] for key in ('grows', 'shrinks', 'grow_ticks', 'shrink_ticks')):
            raise ValueError('launch counters precede boot counters')
        delta = {key: after[key]-before[key] for key in ('grows', 'shrinks', 'grow_ticks', 'shrink_ticks')}
        if any(value < 0 for value in delta.values()) or after['chunks']-before['chunks'] != delta['grows']-delta['shrinks']:
            raise ValueError('accounting window is not monotonic')
        if after['live'] != 1 or after['chunks'] != retain+1:
            raise ValueError('benchmark resources remain or reserve differs')
        result['pools'][pool] = dict(delta, final_bytes=after['bytes'])
    return result


def summarize(paths):
    rows = [parse(path.read_text()) for path in paths]
    if {r['retain'] for r in rows} != {0, 1}:
        raise ValueError('both policies are required')
    if len({r['frequency'] for r in rows}) != 1:
        raise ValueError('platform clocks cannot be mixed')
    lines = ['retain\tboots\tcount\tbatches\tmedian_batch_ns\tp25_batch_ns\tp75_batch_ns']
    for retain in (1, 0):
        selected = [r for r in rows if r['retain'] == retain]
        for count in COUNTS:
            samples = [t['ns'] for r in selected for t in r['timings'] if t['count'] == count]
            q = statistics.quantiles(samples, n=4, method='inclusive')
            lines.append('\t'.join(map(str, (retain, len(selected), count, len(samples), int(statistics.median(samples)), int(q[0]), int(q[2])))))
    lines += ['', 'retain\tpool\tboots\tgrows_per_boot\tshrinks_per_boot\tfinal_bytes\tmedian_grow_ticks\tmedian_shrink_ticks']
    for retain in (1, 0):
        selected = [r for r in rows if r['retain'] == retain]
        for pool in ('fd_block', 'object'):
            samples = [r['pools'][pool] for r in selected]
            if len({(r['grows'], r['shrinks'], r['final_bytes']) for r in samples}) != 1:
                raise ValueError('allocation/storage counts did not reproduce')
            row = samples[0]
            lines.append('\t'.join(map(str, (retain, pool, len(samples), row['grows'], row['shrinks'], row['final_bytes'], int(statistics.median(r['grow_ticks'] for r in samples)), int(statistics.median(r['shrink_ticks'] for r in samples))))))
    return '\n'.join(lines)+'\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', nargs='+', type=Path)
    args = parser.parse_args()
    try: print(summarize(args.captures), end='')
    except ValueError as error: parser.exit(1, str(error)+'\n')


if __name__ == '__main__':
    main()
