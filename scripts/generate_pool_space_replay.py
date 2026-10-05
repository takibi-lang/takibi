#!/usr/bin/env python3
"""Specialize the tracked replay template; generated output contains no originals."""
import argparse
import csv
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--c-header', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    rows = list(csv.DictReader((root / 'kernel/benchmarks/pool_space/workload.tsv').open(), delimiter='\t'))
    expected = {'process','tcp','retx','frame','backing','image','fd_context','fd_block','object'}
    if len(rows) != 9 or {row['name'] for row in rows} != expected:
        parser.error('workload must describe all nine current production pool sizes')
    if args.c_header:
        if any(int(row['object_bytes']) <= 0 or int(row['alignment']) != 8 for row in rows):
            parser.error('unexpected payload size or alignment')
        names = ','.join('"' + row['name'] + '"' for row in rows)
        sizes = ','.join(row['object_bytes'] for row in rows)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text('/* Derived from the tracked workload.tsv. */\n'
                              '#define REPLAY_MAX 128\n'
                              f'static const char *names[]={{ {names} }};\n'
                              f'static const unsigned sizes[]={{ {sizes} }};\n')
        return
    template = (root / 'linux_user/pool_space_replay/region_replay.tkb.in').read_text()
    if 'fn replay_region(' not in template or 'replay_region_row' not in template:
        parser.error('replay template is empty or missing its entry/report')
    out = ['// Derived payload types and concrete region replay bodies.\n',
           'const REPLAY_MAX: usize = 128;\n',
           'struct ReplayWords { address: usize; generation: usize; }\n',
           'must_use variant ReplayAllocation { Failed; Ready(ReplayWords); }\n']
    for row in rows:
        name = row['name']
        size = int(row['object_bytes'])
        if size <= 0 or int(row['alignment']) != 8:
            parser.error('unexpected payload size or alignment')
        out.append(f'struct Replay_{name} align(8) {{ bytes: [u8; {size}]; }}\n')
    out.append('private let mut replay_words: [ReplayWords; REPLAY_MAX];\n')
    for row in rows[1:]:
        name = row['name']
        body = re.sub(r'\bT:\s*type,\s*', '', template)
        body = re.sub(r'\bT\b', 'Replay_' + name, body)
        body = body.replace('(Replay_' + name + ', guard', '(guard')
        body = re.sub(r'\breplay_region(\w*)\b', r'replay_region\1_' + name, body)
        out.append(body)
    text = '\n'.join(out)
    if text.count('fn replay_region_') != 40:
        parser.error('generated replay is degenerate: expected five bodies for eight pools')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)


if __name__ == '__main__':
    main()
