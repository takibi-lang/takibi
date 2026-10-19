#!/usr/bin/env python3
"""Rebase onto an upstream, resolving docs/SPACE_CHECKPOINT.json-only conflicts.

Almost every land rewrites the space checkpoint, so a queued branch nearly
always conflicts on it (GitHub issue #832). This helper runs the rebase and,
at each stop whose ONLY unmerged path is that file, takes the upstream side
and continues. Any other unmerged path leaves the rebase stopped exactly as a
plain `git rebase` would, and exits 4.

When it resolved such a conflict, the merged checkpoint is upstream's record,
stale for the branch's production sources. It is re-recorded: the branch's
own pre-rebase review (which must have been valid for the branch's
pre-rebase head) is written back with source_sha256 recomputed for the
rebased head, in one new commit. The review content is the branch's, the
binding is to the tree that will be tested; scripts/land.sh then runs
space_checkpoint and the full check on that new head, so nothing is skipped.
A branch whose own review was missing or stale is not blessed here: exit 2.

Exit status: 0 rebased (and re-recorded if needed); 2 the checkpoint needs a
review; 4 the rebase stopped on a conflict outside the checkpoint.
"""
import argparse
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True
from space_checkpoint import REVIEW, production_source, source_digest, tree_entries, validate_review


def git(*args, check=True, env=None):
    result = subprocess.run(['git', *args], text=True, capture_output=True, env=env)
    if check and result.returncode != 0:
        raise SystemExit(f'checkpoint_rebase: git {" ".join(args)} failed:\n{result.stderr}')
    return result


def out(*args):
    return git(*args).stdout.strip()


def unmerged():
    return sorted(set(out('diff', '--name-only', '--diff-filter=U').splitlines()))


def review_valid(head, base):
    """True when HEAD's checkpoint passes space_checkpoint against BASE."""
    entries = tree_entries(head)
    changed = out('diff', '--name-only', base, head).splitlines()
    if not any(production_source(path) for path in changed):
        return True
    if REVIEW not in entries:
        return False
    try:
        validate_review(json.loads(out('show', f'{head}:{REVIEW}')),
                        source_digest(entries), entries)
    except ValueError:
        return False
    return True


def rebase(onto, env):
    """Run the rebase; return the number of checkpoint-only stops resolved."""
    resolved = 0
    step = git('rebase', '--rebase-merges', onto, check=False, env=env)
    while step.returncode != 0:
        paths = unmerged()
        if paths != [REVIEW]:
            sys.stderr.write(step.stdout + step.stderr)
            print('checkpoint_rebase: conflict outside ' + REVIEW + ': ' +
                  (', '.join(p for p in paths if p != REVIEW) or 'no unmerged path'), file=sys.stderr)
            return None
        # During a rebase "ours" is the upstream side being built on.
        git('checkout', '--ours', '--', REVIEW)
        git('add', '--', REVIEW)
        resolved += 1
        print(f'checkpoint_rebase: took upstream {REVIEW} at {out("rev-parse", "--short", "REBASE_HEAD")}')
        if git('diff', '--cached', '--quiet', check=False).returncode == 0:
            step = git('rebase', '--skip', check=False, env=env)
        else:
            step = git('-c', 'core.editor=true', 'rebase', '--continue', check=False,
                       env=dict(env, GIT_EDITOR='true'))
    return resolved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--onto', default='origin/main')
    args = parser.parse_args()
    os.chdir(out("rev-parse", "--show-toplevel"))
    orig = out('rev-parse', 'HEAD')
    upstream = out('rev-parse', args.onto)
    old_base = out('merge-base', orig, upstream)
    author = {'GIT_AUTHOR_NAME': out('log', '-1', '--format=%an', orig),
              'GIT_AUTHOR_EMAIL': out('log', '-1', '--format=%ae', orig)}
    env = dict(os.environ)
    for key, value in author.items():
        env.setdefault(key, value)
        env.setdefault(key.replace('AUTHOR', 'COMMITTER'), value)
    resolved = rebase(args.onto, env)
    if resolved is None:
        return 4
    head = out('rev-parse', 'HEAD')
    if not resolved or review_valid(head, upstream):
        return 0
    if not review_valid(orig, old_base):
        print(f'checkpoint_rebase: the branch\'s own {REVIEW} was not current before the '
              'rebase; review it (docs/SPACE_REVIEW.md)', file=sys.stderr)
        return 2
    review = json.loads(out('show', f'{orig}:{REVIEW}'))
    upstream_review = json.loads(out('show', f'{upstream}:{REVIEW}'))
    review['source_sha256'] = source_digest(tree_entries(head))
    review['workload'] = (
        f'Re-recorded by scripts/checkpoint_rebase.py after a rebase onto {upstream[:8]}: '
        f'this branch\'s review, rebound to the merged sources (upstream\'s record was '
        f'{upstream_review.get("date")} {upstream_review.get("event")}/{upstream_review.get("decision")}). ' + review['workload'])
    with open(REVIEW, 'w', encoding='utf-8') as handle:
        json.dump(review, handle, indent=2, ensure_ascii=False)
        handle.write('\n')
    git('add', '--', REVIEW)
    git('commit', '--quiet', '-m', f'Space checkpoint: re-recorded after rebase onto {upstream[:8]}',
        '-m', 'Written by scripts/checkpoint_rebase.py (#832): the branch review, rebound to the rebased sources.',
        env=env)
    if not review_valid('HEAD', upstream):
        print('checkpoint_rebase: re-recorded checkpoint does not validate', file=sys.stderr)
        return 2
    print(f'checkpoint_rebase: re-recorded {REVIEW} for {out("rev-parse", "--short", "HEAD")}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
