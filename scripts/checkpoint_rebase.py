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

A conflict in kernel/models/README.md is resolved too when it is
review-stamp-only (GitHub issue #833): the three stages, with every row's
Reviewed cell blanked, merge cleanly. Merged rows keep upstream's stamp
(else the branch's); after the rebase finishes,
`make model-map-restamp` runs on the rebased tree and its result is
committed: it compiles both kernels' main.o for their --facts callgraph.tsv
tables (GitHub issue #987; the stamps are the compiler's body hashes) and
runs scripts/buildcheck_model_function_map.py --restamp over them. That
happens before the checkpoint re-record, so the re-recorded review covers
the final tree. Any other README conflict is
a conflict like any other: exit 4.

docs/TRUST_LEDGER.json (GitHub issue #1438) is the third such file: a
branch that appended ledger entries meets upstream's own appends, either as
a conflict or as a clean merge whose series is out of order. A conflict
there takes upstream's side, as the checkpoint does. After the rebase, when
the branch had appended entries and either one of them is missing from the
rebased series (a conflict took upstream's side) or `scripts/check_trust_ledger.py`
refuses the rebased tree, the ledger is reset to upstream's and the branch's
reasons are re-appended in one entry measured on the rebased tree
(`--append --reason CAT=TEXT ...`), in one new commit. If that append is
refused too, the helper stops: exit 4.

Known append-only files (GitHub issue #1443) are merged, not stopped on:
both sides of a conflict are kept. Two kinds:

- UNION_TEXT: tables and logs whose entries are only appended
  (docs/GLOBAL_PROTECTION.md's migration log, check_trust_ledger.py's RULES
  table): `git merge-file --union` keeps every hunk of both sides.
- UNION_ROWS: row-set TSVs (global_protection_allowlist.tsv,
  invariant_stop_sites.tsv): the merged file is upstream's rows, less any
  base row the branch deleted, plus the rows the branch added. A row deleted
  on either side stays deleted; a row changed on both sides is kept in both
  forms, which the file's own check then refuses with the row named.

`--stack B1 B2 ...` rebases a stack bottom-up: B1 onto --onto, then each
next branch onto its rebased predecessor, cutting at the predecessor's old
head, each with the same resolutions. It stops at the first branch that
does not finish, with that branch checked out.

Exit status: 0 rebased (and re-recorded if needed); 2 the checkpoint needs a
review; 4 the rebase stopped on a conflict other than the checkpoint and a
stamp-only model map, or the restamped model map does not check.
"""
import argparse
import json
import os
import re
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


MODEL_MAP = 'kernel/models/README.md'
LEDGER = 'docs/TRUST_LEDGER.json'
LEDGER_CHECK = 'scripts/check_trust_ledger.py'
UNION_TEXT = ('docs/GLOBAL_PROTECTION.md', 'scripts/check_trust_ledger.py')
UNION_ROWS = ('scripts/global_protection_allowlist.tsv', 'scripts/invariant_stop_sites.tsv')


def stage_text(path, stage):
    shown = git('show', f':{stage}:{path}', check=False)
    return shown.stdout if shown.returncode == 0 else None


def union_rows(base, ours, theirs):
    """Upstream's rows, less base rows the branch deleted, plus the branch's new rows."""
    base_rows = base.splitlines(keepends=True)
    theirs_rows = theirs.splitlines(keepends=True)
    deleted = set(base_rows) - set(theirs_rows)
    kept = [row for row in ours.splitlines(keepends=True) if row not in deleted]
    present = set(kept)
    added = [row for row in theirs_rows if row not in set(base_rows) and row not in present]
    if kept and not kept[-1].endswith('\n'):
        kept[-1] += '\n'
    return ''.join(kept + added)


def resolve_union(path):
    """Keep both sides of PATH's conflict (#1443); False when it cannot."""
    base, ours, theirs = (stage_text(path, n) for n in (1, 2, 3))
    if ours is None or theirs is None:
        return False
    base = base or ''
    if path in UNION_ROWS:
        merged = union_rows(base, ours, theirs)
    else:
        git_dir = out('rev-parse', '--git-dir')
        names = []
        for stage, text in ((2, ours), (1, base), (3, theirs)):
            name = os.path.join(git_dir, f'checkpoint-rebase-union{stage}')
            with open(name, 'w', encoding='utf-8') as handle:
                handle.write(text)
            names.append(name)
        result = git('merge-file', '-p', '--union', *names, check=False)
        for name in names:
            os.remove(name)
        if result.returncode < 0:
            return False
        merged = result.stdout
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(merged)
    git('add', '--', path)
    return True
STAMP_RE = re.compile(r'^(\| `.*\|) `[0-9a-f]+` \|$')
BLANK = ' `-` |'


def blank_stamps(text):
    """TEXT with every action row's Reviewed cell blanked, and each blanked row's original."""
    lines, stamps = [], {}
    for line in text.splitlines(keepends=True):
        match = STAMP_RE.match(line.rstrip('\n'))
        if match:
            blanked = match.group(1) + BLANK + ('\n' if line.endswith('\n') else '')
            stamps.setdefault(blanked, line)
            line = blanked
        lines.append(line)
    return ''.join(lines), stamps


def resolve_stamp_only(path):
    """Resolve PATH's conflict when it lies in Reviewed stamps only; False otherwise."""
    stages = {}
    for stage in (1, 2, 3):
        shown = git('show', f':{stage}:{path}', check=False)
        if shown.returncode != 0:
            return False
        stages[stage] = blank_stamps(shown.stdout)
    git_dir = out('rev-parse', '--git-dir')
    names = []
    for stage in (2, 1, 3):
        name = os.path.join(git_dir, f'checkpoint-rebase-stage{stage}')
        with open(name, 'w', encoding='utf-8') as handle:
            handle.write(stages[stage][0])
        names.append(name)
    merged = git('merge-file', '-p', *names, check=False)
    for name in names:
        os.remove(name)
    if merged.returncode != 0:
        return False
    # During a rebase stage 2 ("ours") is the upstream side being built on.
    pick = [stages[2][1], stages[3][1], stages[1][1]]
    lines = [next((s[line] for s in pick if line in s), line)
             for line in merged.stdout.splitlines(keepends=True)]
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(''.join(lines))
    git('add', '--', path)
    return True


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


def rebase(onto, env, cut=None):
    """Run the rebase; return (checkpoint stops resolved, model map stops resolved)."""
    resolved = stamped = 0
    args = ['rebase', '--rebase-merges'] + (['--onto', onto, cut] if cut else [onto])
    step = git(*args, check=False, env=env)
    while step.returncode != 0:
        paths = unmerged()
        unions = [p for p in paths if p in UNION_TEXT + UNION_ROWS]
        others = [p for p in paths if p not in (REVIEW, MODEL_MAP, LEDGER) and p not in unions]
        if (not paths or others or (MODEL_MAP in paths and not resolve_stamp_only(MODEL_MAP))
                or not all(resolve_union(p) for p in unions)):
            sys.stderr.write(step.stdout + step.stderr)
            print('checkpoint_rebase: conflict outside ' + REVIEW + ' and a stamp-only ' +
                  MODEL_MAP + ': ' + (', '.join(p for p in paths if p != REVIEW)
                                      or 'no unmerged path'), file=sys.stderr)
            return None
        at = out('rev-parse', '--short', 'REBASE_HEAD')
        for path in unions:
            print(f'checkpoint_rebase: kept both sides of append-only {path} at {at}')
        if MODEL_MAP in paths:
            stamped += 1
            print(f'checkpoint_rebase: merged stamp-only {MODEL_MAP} conflict at {at}')
        if REVIEW in paths:
            # During a rebase "ours" is the upstream side being built on.
            git('checkout', '--ours', '--', REVIEW)
            git('add', '--', REVIEW)
            resolved += 1
            print(f'checkpoint_rebase: took upstream {REVIEW} at {at}')
        if LEDGER in paths:
            # Upstream's series; the branch's entries are re-appended after
            # the rebase (relog).
            git('checkout', '--ours', '--', LEDGER)
            git('add', '--', LEDGER)
            print(f'checkpoint_rebase: took upstream {LEDGER} at {at}')
        if git('diff', '--cached', '--quiet', check=False).returncode == 0:
            step = git('rebase', '--skip', check=False, env=env)
        else:
            step = git('-c', 'core.editor=true', 'rebase', '--continue', check=False,
                       env=dict(env, GIT_EDITOR='true'))
    return resolved, stamped


def restamp_map(env, upstream):
    """Restamp the model map on the rebased tree and commit it; False when it does not check."""
    result = subprocess.run(['make', '--no-print-directory', 'model-map-restamp'],
                            text=True, capture_output=True, env=env)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        print(f'checkpoint_rebase: the restamped {MODEL_MAP} does not check; the rebase is '
              'finished and the restamp is left uncommitted', file=sys.stderr)
        return False
    if git('diff', '--quiet', '--', MODEL_MAP, check=False).returncode != 0:
        git('add', '--', MODEL_MAP)
        git('commit', '--quiet', '-m', f'Model map: restamp after rebase onto {upstream[:8]}',
            '-m', 'Written by scripts/checkpoint_rebase.py (#833): the rebase met a conflict in '
            'the Reviewed stamps only; the rows were re-hashed on the rebased tree.', env=env)
        print(f'checkpoint_rebase: restamped {MODEL_MAP} at {out("rev-parse", "--short", "HEAD")}')
    return True


def ledger_series(rev):
    shown = git('show', f'{rev}:{LEDGER}', check=False)
    if shown.returncode != 0:
        return None
    return json.loads(shown.stdout).get('series', [])


def relog(orig, old_base, upstream, env):
    """Re-append the branch's ledger entries on the rebased tree; False when refused."""
    mine, base = ledger_series(orig), ledger_series(old_base)
    if mine is None or not os.path.exists(LEDGER_CHECK):
        return True
    seen = {json.dumps(e, sort_keys=True) for e in (base or [])}
    added = [e for e in mine if json.dumps(e, sort_keys=True) not in seen]
    if not added:
        return True
    now = {json.dumps(e, sort_keys=True) for e in (ledger_series('HEAD') or [])}
    check = subprocess.run([sys.executable, LEDGER_CHECK], text=True, capture_output=True)
    if check.returncode == 0 and all(json.dumps(e, sort_keys=True) in now for e in added):
        return True
    reasons = {}
    for entry in added:
        for category, text in entry.get('changes', {}).items():
            reasons[category] = (reasons[category] + '; ' + text) if category in reasons else text
    upstream_text = git('show', f'{upstream}:{LEDGER}', check=False)
    if upstream_text.returncode == 0:
        with open(LEDGER, 'w', encoding='utf-8') as handle:
            handle.write(upstream_text.stdout)
    args = [sys.executable, LEDGER_CHECK, '--append']
    for category, text in sorted(reasons.items()):
        args += ['--reason', f'{category}={text}']
    appended = subprocess.run(args, text=True, capture_output=True)
    if appended.returncode != 0:
        sys.stderr.write(check.stdout + appended.stdout + appended.stderr)
        print(f'checkpoint_rebase: re-appending the branch\'s {LEDGER} entries was refused; '
              'the rebase is finished and the ledger is left uncommitted', file=sys.stderr)
        return False
    git('add', '--', LEDGER)
    git('commit', '--quiet', '-m', f'Trust ledger: re-appended after rebase onto {upstream[:8]}',
        '-m', 'Written by scripts/checkpoint_rebase.py (#1438): the branch\'s ledger entries '
        'did not check on the rebased tree, so upstream\'s series was kept and their reasons '
        're-appended in one entry measured here.', env=env)
    print(f'checkpoint_rebase: re-appended {LEDGER} at {out("rev-parse", "--short", "HEAD")}')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--onto', default='origin/main')
    parser.add_argument('--stack', nargs='+', metavar='BRANCH',
                        help='rebase these branches bottom-up, each onto the one before')
    args = parser.parse_args()
    os.chdir(out("rev-parse", "--show-toplevel"))
    if not args.stack:
        return rebase_one(args.onto, None)
    onto = args.onto
    cut = None
    for branch in args.stack:
        old_head = out('rev-parse', branch)
        git('checkout', '--quiet', branch)
        status = rebase_one(onto, cut)
        if status != 0:
            print(f'checkpoint_rebase: stack stopped at {branch} (exit {status})', file=sys.stderr)
            return status
        print(f'checkpoint_rebase: {branch} rebased to {out("rev-parse", "--short", "HEAD")}')
        onto, cut = out('rev-parse', 'HEAD'), old_head
    return 0


def rebase_one(onto_ref, cut):
    """Rebase the checked-out branch onto ONTO_REF (from CUT when given)."""
    orig = out('rev-parse', 'HEAD')
    upstream = out('rev-parse', onto_ref)
    old_base = cut or out('merge-base', orig, upstream)
    author = {'GIT_AUTHOR_NAME': out('log', '-1', '--format=%an', orig),
              'GIT_AUTHOR_EMAIL': out('log', '-1', '--format=%ae', orig)}
    env = dict(os.environ)
    for key, value in author.items():
        env.setdefault(key, value)
        env.setdefault(key.replace('AUTHOR', 'COMMITTER'), value)
    outcome = rebase(upstream, env, cut)
    if outcome is None:
        return 4
    resolved, stamped = outcome
    if stamped and not restamp_map(env, upstream):
        return 4
    if not relog(orig, old_base, upstream, env):
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
