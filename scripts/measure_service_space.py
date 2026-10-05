#!/usr/bin/env python3
"""Validate the small FD/fork service trace; report logical bookkeeping only."""
import argparse
import json
import re
from pathlib import Path

PHASES = ('baseline', 'opened', 'inherited', 'reaped', 'closed')
FIELDS = {'pid', 'fds', 'regular', 'capacity', 'process', 'fd_body', 'fd_dynamic', 'file_body', 'hash', 'minrefs', 'maxrefs'}
POOL_LAYOUT = {'process': (9, 8192), 'fd_context': (50, 4096), 'fd_block': (7, 4096), 'object': (46, 4096), 'image': (42, 4096), 'backing': (84, 4096)}


def validate_pools(sample, actors, regular, teardown=False, fd_block_size=528):
    if fd_block_size not in (528, 400):
        raise ValueError('unsupported FD block layout')
    layout = dict(POOL_LAYOUT, fd_block=(7 if fd_block_size == 528 else 9, 4096))
    pools = sample['pools']
    if set(pools) != set(POOL_LAYOUT):
        raise ValueError('missing or unknown Takibi pool')
    for key, (slots, chunk) in layout.items():
        row = pools[key]
        if set(row) != {'live', 'chunks', 'capacity', 'bytes'} or any(type(value) is not int or value < 0 for value in row.values()):
            raise ValueError('malformed Takibi pool sample')
        if row['capacity'] != row['chunks'] * slots or row['bytes'] != row['chunks'] * chunk or row['live'] > row['capacity']:
            raise ValueError('Takibi pool capacity/storage mismatch')
    expected = dict(process=len(actors), backing=len(actors), image=len(actors)+1,
                    fd_context=len(actors)+1, object=regular+1,
                    fd_block=1+sum(a['capacity']//16 for a in actors))
    if any(pools[key]['live'] != live for key, live in expected.items()):
        raise ValueError('Takibi pooled objects do not match the service resources')
    if teardown and sample['actors']:
        raise ValueError('Takibi retained a benchmark process after exit')


def parse_capture(text, os, fd_block_size=528):
    rows = []
    phase = None
    parent = None
    done = status = teardown = False
    for raw in text.splitlines():
        line = raw.strip()
        match = re.fullmatch(r'service replay: count=(\d+) phase=(\w+) pid=(\d+)', line)
        if match:
            if phase and len(phase['actors']) != (2 if phase['phase'] == 'inherited' else 1):
                raise ValueError('phase lacks its complete actor observations')
            if done or len(rows) >= 10:
                raise ValueError('duplicate or trailing phase')
            count, name, pid = int(match[1]), match[2], int(match[3])
            if (count, name) != ((32, 128)[len(rows)//5], PHASES[len(rows)%5]) or pid <= 0:
                raise ValueError('service phases do not match the common sequence')
            if parent is None:
                parent = pid
            if (name == 'inherited') == (pid == parent):
                raise ValueError('wrong parent/child marker PID')
            phase = dict(count=count, phase=name, marker_pid=pid, parent=parent, actors=[])
            rows.append(phase)
        elif line.startswith('service space:'):
            if os == 'takibi' or phase is None or done:
                raise ValueError('unframed actor observation')
            pairs = [part.split('=') for part in line.removeprefix('service space: ').split()]
            if any(len(pair) != 2 or not pair[1].isdigit() for pair in pairs):
                raise ValueError('malformed actor observation')
            actor = dict((key, int(value)) for key, value in pairs)
            extra = {'fd_dynamic_usable'} | ({'threads', 'retired'} if os == 'freebsd' else set())
            if len(actor) != len(pairs) or set(actor) != FIELDS | extra:
                raise ValueError('duplicate, missing, or unknown actor field')
            if actor['fd_dynamic_usable'] < actor['fd_dynamic'] or (os == 'freebsd' and (actor['threads'] != 1 or actor['retired'] != 0)):
                raise ValueError('unsupported actor allocation/lifetime shape')
            phase['actors'].append(actor)
        elif line.startswith('service pools:'):
            if os != 'takibi' or phase is None or phase['actors'] or done:
                raise ValueError('unframed or duplicate Takibi observation')
            sample = json.loads(line.removeprefix('service pools: '))
            phase['actors'] = sample['actors']
            regular = phase['count'] if phase['phase'] in ('opened', 'inherited', 'reaped') else 0
            validate_pools(sample, phase['actors'], regular, fd_block_size=fd_block_size)
            phase['pools'] = sample['pools']
        elif line == 'service replay: done':
            if done or len(rows) != 10 or len(rows[-1]['actors']) != 1:
                raise ValueError('premature or duplicate completion')
            done = True
        elif line.startswith('service replay: status='):
            if not done or status or line != 'service replay: status=0':
                raise ValueError('benchmark did not exit successfully')
            status = True
        elif line.startswith('service teardown:'):
            if os != 'takibi' or not status or teardown:
                raise ValueError('unframed or duplicate teardown')
            sample = json.loads(line.removeprefix('service teardown: '))
            validate_pools(sample, [], 0, teardown=True, fd_block_size=fd_block_size)
            teardown = True
        else:
            raise ValueError('unexpected or failed benchmark output')
    if len(rows) != 10 or not done or not status or (os == 'takibi' and not teardown):
        raise ValueError('incomplete service trace or teardown')
    sizes = None
    for row in rows:
        inherited = row['phase'] == 'inherited'
        actors = row['actors']
        ids = [parent, row['marker_pid']] if inherited else [parent]
        regular = row['count'] if row['phase'] in ('opened', 'inherited', 'reaped') else 0
        refs = (2 if inherited else 1) if regular else 0
        if [actor['pid'] for actor in actors] != ids:
            raise ValueError('actor count/order differs from the observed parent/child')
        for actor in actors:
            if not FIELDS <= set(actor) or any(type(v) is not int or v < 0 for v in actor.values()):
                raise ValueError('malformed actor data')
            if actor['fds'] != regular+3 or actor['regular'] != regular or actor['capacity'] < actor['fds'] or actor['minrefs'] != refs or actor['maxrefs'] != refs:
                raise ValueError('FD count, capacity, or file sharing differs from the workload')
            if os == 'takibi' and (actor['capacity'] % 16 or actor['fd_dynamic'] != actor['capacity']//16*fd_block_size):
                raise ValueError('FD block payload does not match selected layout')
            layout = tuple(actor[key] for key in ('process', 'fd_body', 'file_body'))
            if min(layout) <= 0 or (sizes is not None and layout != sizes):
                raise ValueError('record layout changed within the trace')
            sizes = layout
            if not regular and actor['hash'] != 0:
                raise ValueError('empty regular-FD mapping has a fingerprint')
        if inherited and actors[0]['hash'] != actors[1]['hash']:
            raise ValueError('inherited open-description fingerprints differ')
        row['fd_payload_bytes'] = sum(a['fd_body']+a['fd_dynamic'] for a in actors)+regular*actors[0]['file_body']
        row['process_payload_bytes'] = sum(a['process'] for a in actors)
        row['unique_regular_descriptions'] = regular
    for offset in (0, 5):
        opened, reaped, closed = (rows[offset+index]['actors'][0] for index in (1, 3, 4))
        inherited = rows[offset+2]['actors'][0]
        if opened['hash'] != inherited['hash'] or opened['hash'] != reaped['hash']:
            raise ValueError('parent open-description mapping changed across fork/wait')
        if any(opened[key] != actor[key] for actor in (reaped, closed) for key in ('capacity', 'fd_body', 'fd_dynamic')):
            raise ValueError('dated trace no longer supports the retained-table observation')
    if any(rows[4]['actors'][0][key] != rows[5]['actors'][0][key] for key in ('capacity', 'fd_body', 'fd_dynamic')):
        raise ValueError('second count did not continue with the same process/table')
    return rows


def render_tsv(captures):
    lines = ['os\tcount\tphase\tactors\tfds_per_actor\tregular_descriptions\tfd_payload_bytes\tprocess_payload_bytes']
    for os, rows in captures.items():
        for row in rows:
            lines.append(f"{os}\t{row['count']}\t{row['phase']}\t{len(row['actors'])}\t{row['actors'][0]['fds']}\t{row['unique_regular_descriptions']}\t{row['fd_payload_bytes']}\t{row['process_payload_bytes']}")
    return '\n'.join(lines)+'\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for os in ('takibi', 'linux', 'freebsd'):
        parser.add_argument('--'+os, type=Path, required=True)
    parser.add_argument('--takibi-fd-block-size', type=int, choices=(528, 400), default=528)
    args = parser.parse_args()
    try:
        print(render_tsv({os: parse_capture(getattr(args, os).read_text(), os, args.takibi_fd_block_size) for os in ('takibi', 'linux', 'freebsd')}), end='')
    except (ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'service space: {error}\n')


if __name__ == '__main__':
    main()
