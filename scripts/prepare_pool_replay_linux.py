#!/usr/bin/env python3
"""Extract private observation headers from matching Linux 6.12.111 source."""
import argparse
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    version = dict(re.findall(r'^(VERSION|PATCHLEVEL|SUBLEVEL)\s*=\s*(\d+)\s*$',
                              (args.source / 'Makefile').read_text(), re.M))
    if version != {'VERSION': '6', 'PATCHLEVEL': '12', 'SUBLEVEL': '111'}:
        parser.error('private observation types require Linux 6.12.111 source')
    source = (args.source / 'mm/slub.c').read_text()
    types = []
    for name in ('kmem_cache_cpu', 'kmem_cache_node'):
        match = re.search(r'^struct ' + name + r' \{.*?^\};', source, re.M | re.S)
        if match is None:
            parser.error('matching source is missing ' + name)
        types.append(match[0])
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'slub-observation-types.h').write_text(
        '/* Observation-only types extracted from the matching Linux source. */\n' + '\n'.join(types) + '\n')
    (args.output / 'slab-internal.h').write_text((args.source / 'mm/slab.h').read_text())


if __name__ == '__main__':
    main()
