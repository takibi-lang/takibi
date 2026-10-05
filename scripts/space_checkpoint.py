#!/usr/bin/env python3
"""Require a current space review at the natural publication boundary.

Git tree blob identities bind the review to production sources without a
self-referential commit hash. This gate enforces a review, not the truth of a
human workload assessment; measurements retain their actual evidence boundary.
"""
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import sys

REVIEW = 'docs/SPACE_CHECKPOINT.json'
FIELDS = {'date', 'event', 'decision', 'source_sha256', 'workload',
          'evidence', 'assessment', 'next_trigger'}


def production_source(path):
    if path == 'Makefile':
        return True
    if path.startswith(('lib/', 'bin/')):
        return path.endswith(('.ml', '.mli', '.mly', '.mll'))
    return (path.startswith('kernel/') and
            not path.startswith('kernel/benchmarks/') and
            path.endswith(('.tkb', '.c', '.h', '.S', '.ld')))


def source_digest(entries):
    rows = [f'{path}\t{blob}\n' for path, blob in sorted(entries.items())
            if production_source(path)]
    if not rows:
        raise ValueError('production source scope is empty')
    return hashlib.sha256(''.join(rows).encode('ascii')).hexdigest()


def validate_review(review, digest, entries):
    if not isinstance(review, dict) or set(review) != FIELDS:
        raise ValueError('space checkpoint has missing or unknown fields')
    for key in FIELDS - {'evidence'}:
        if not isinstance(review[key], str) or not review[key].strip():
            raise ValueError(f'space checkpoint needs a nonempty {key}')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', review['date']):
        raise ValueError('space checkpoint date must be YYYY-MM-DD')
    datetime.date.fromisoformat(review['date'])
    if review['source_sha256'] != digest:
        raise ValueError('space checkpoint is stale for these production sources')
    if review['event'] not in ('milestone', 'incremental'):
        raise ValueError('event must be milestone or incremental')
    if review['decision'] not in ('measured', 'reuse'):
        raise ValueError('decision must be measured or reuse')
    if review['event'] == 'milestone' and review['decision'] != 'measured':
        raise ValueError('a feature/stage milestone requires measurement')
    evidence = review['evidence']
    if not isinstance(evidence, list) or not evidence:
        raise ValueError('space checkpoint needs tracked evidence')
    for path in evidence:
        if (not isinstance(path, str) or path not in entries or path == REVIEW or
                path.startswith('/') or '..' in path.split('/')):
            raise ValueError('evidence must name a tracked report or capture')
        if entries[path] == 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391':
            raise ValueError('space evidence cannot be an empty blob')


def git(*args):
    return subprocess.check_output(['git', *args], text=True)


def tree_entries(head):
    entries = {}
    for row in git('ls-tree', '-r', head).splitlines():
        meta, path = row.split('\t', 1)
        mode, kind, blob = meta.split()
        if kind == 'blob' and mode in ('100644', '100755'):
            entries[path] = blob
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='origin/main')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--digest', action='store_true')
    args = parser.parse_args()
    try:
        entries = tree_entries(args.head)
        digest = source_digest(entries)
        if args.digest:
            print(digest)
            return 0
        changed = git('diff', '--name-only', args.base, args.head).splitlines()
        if not any(production_source(path) for path in changed):
            print('space checkpoint: no production source change in this publication')
            return 0
        if REVIEW not in entries:
            raise ValueError(f'missing {REVIEW}')
        review = json.loads(git('show', f'{args.head}:{REVIEW}'))
        validate_review(review, digest, entries)
        print(f"space checkpoint: {review['event']}, {review['decision']}, {review['date']}")
        print(f"space checkpoint: next measurement trigger: {review['next_trigger']}")
        return 0
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f'space checkpoint: {error}', file=sys.stderr)
        print('Review docs/SPACE_REVIEW.md and commit current evidence before publishing.',
              file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
