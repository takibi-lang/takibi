#!/usr/bin/env python3
"""Drive scripts/checkpoint_rebase.py against scripted throwaway Git repos.

A conflict confined to docs/SPACE_CHECKPOINT.json must resolve to the
branch's review rebound to the rebased sources; a conflict that also touches
any other file must leave the rebase stopped (exit 4); a branch whose own
review was stale must not be blessed (exit 2). Real git, no network.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from pass_line import report_pass
from space_checkpoint import REVIEW, source_digest, tree_entries

SCRIPTS = Path(__file__).resolve().parent
HELPER = SCRIPTS / 'checkpoint_rebase.py'
CHECK = SCRIPTS / 'space_checkpoint.py'


class Repo:
    def __init__(self, root):
        self.root = root
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.git('init', '-q', '-b', 'main')

    def git(self, *args, check=True):
        return subprocess.run(['git', *args], cwd=self.root, env=self.env, text=True,
                              capture_output=True, check=check)

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message, review=None):
        """Commit the tree; with REVIEW text, first stamp a review valid for it."""
        self.git('add', '-A')
        if review is not None:
            self.git('commit', '-q', '-m', message + ' (sources)')
            digest = source_digest(self.entries())
            record = dict(date='2026-10-19', event='incremental', decision='reuse',
                          source_sha256=digest, workload=review, evidence=['docs/evidence.tsv'],
                          assessment='fixture', next_trigger='fixture')
            self.write(REVIEW, json.dumps(record, indent=2) + '\n')
            self.git('add', '-A')
        self.git('commit', '-q', '-m', message)

    def entries(self):
        cwd = os.getcwd()
        os.chdir(self.root)
        try:
            return tree_entries('HEAD')
        finally:
            os.chdir(cwd)

    def run(self, script, *args):
        return subprocess.run([sys.executable, str(script), *args], cwd=self.root, env=self.env,
                              text=True, capture_output=True)


def scenario(tmp, *, mixed=False, stale=False):
    repo = Repo(Path(tmp))
    repo.write('kernel/a.tkb', 'a0\n')
    repo.write('docs/evidence.tsv', 'measured\n')
    repo.write('docs/notes.md', 'base\n')
    repo.commit('base', review='base review')
    repo.git('switch', '-q', '-c', 'topic')
    repo.write('kernel/b.tkb', 'b1\n')
    repo.commit('topic work', review='topic review')
    if mixed:  # same commit as the review, so one stop holds both conflicts
        repo.write('docs/notes.md', 'topic\n')
        repo.git('commit', '-q', '-a', '--amend', '--no-edit')
    if stale:
        repo.write('kernel/b.tkb', 'b2 unreviewed\n')
        repo.commit('topic edit after its review')
    repo.git('switch', '-q', 'main')
    repo.write('kernel/a.tkb', 'a1\n')
    repo.commit('main work', review='main review')
    if mixed:
        repo.write('docs/notes.md', 'main\n')
        repo.git('commit', '-q', '-a', '--amend', '--no-edit')
    repo.git('switch', '-q', 'topic')
    return repo


def main():
    cases = 0
    with tempfile.TemporaryDirectory(prefix='takibi-ckpt-rebase-') as tmp:
        repo = scenario(tmp)
        result = repo.run(HELPER, '--onto', 'main')
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'took upstream' in result.stdout and 're-recorded' in result.stdout, result.stdout
        assert repo.git('merge-base', '--is-ancestor', 'main', 'HEAD', check=False).returncode == 0
        assert (repo.root / 'kernel/b.tkb').read_text() == 'b1\n'
        assert (repo.root / 'kernel/a.tkb').read_text() == 'a1\n'
        record = json.loads((repo.root / REVIEW).read_text())
        assert record['workload'].endswith('topic review'), record
        assert 'upstream\'s record was 2026-10-19' in record['workload'], record
        assert record['source_sha256'] == source_digest(repo.entries())
        assert repo.git('status', '--porcelain').stdout == ''
        check = repo.run(CHECK, '--base', 'main', '--head', 'HEAD')
        assert check.returncode == 0, check.stdout + check.stderr
        cases += 1
    with tempfile.TemporaryDirectory(prefix='takibi-ckpt-rebase-') as tmp:
        repo = scenario(tmp, mixed=True)
        result = repo.run(HELPER, '--onto', 'main')
        assert result.returncode == 4, result.stdout + result.stderr
        assert 'conflict outside' in result.stderr and 'docs/notes.md' in result.stderr, result.stderr
        assert (repo.root / '.git/rebase-merge').exists(), 'mixed conflict must leave the rebase stopped'
        unmerged = repo.git('diff', '--name-only', '--diff-filter=U').stdout.split()
        assert sorted(unmerged) == sorted(['docs/notes.md', REVIEW]), unmerged
        cases += 1
    with tempfile.TemporaryDirectory(prefix='takibi-ckpt-rebase-') as tmp:
        repo = scenario(tmp, stale=True)
        result = repo.run(HELPER, '--onto', 'main')
        assert result.returncode == 2, result.stdout + result.stderr
        assert 'was not current before the rebase' in result.stderr, result.stderr
        assert 'Space checkpoint: re-recorded' not in repo.git('log', '-1', '--format=%s').stdout
        cases += 1
    with tempfile.TemporaryDirectory(prefix='takibi-ckpt-rebase-') as tmp:
        # No conflict at all: the helper is a plain rebase and adds no commit.
        repo = Repo(Path(tmp))
        repo.write('kernel/a.tkb', 'a0\n')
        repo.write('docs/evidence.tsv', 'measured\n')
        repo.commit('base', review='base review')
        repo.git('switch', '-q', '-c', 'topic')
        repo.write('docs/notes.md', 'topic\n')
        repo.commit('docs only')
        repo.git('switch', '-q', 'main')
        repo.write('kernel/a.tkb', 'a1\n')
        repo.commit('main work', review='main review')
        repo.git('switch', '-q', 'topic')
        result = repo.run(HELPER, '--onto', 'main')
        assert result.returncode == 0, result.stdout + result.stderr
        assert repo.git('log', '-1', '--format=%s').stdout.strip() == 'docs only'
        cases += 1
    with tempfile.TemporaryDirectory(prefix='takibi-ckpt-rebase-') as tmp:
        repo = map_scenario(tmp)
        result = repo.run(HELPER, '--onto', 'main')
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'merged stamp-only' in result.stdout and 'restamped' in result.stdout, result.stdout
        subjects = repo.git('log', '-3', '--format=%s').stdout.splitlines()
        assert subjects[0].startswith('Space checkpoint: re-recorded'), subjects
        assert subjects[1].startswith('Model map: restamp'), subjects
        text = (repo.root / MAP).read_text()
        assert 'topic kept' not in text and 'main kept' not in text
        assert text.count(f'`{fake_stamp(repo.root)}`') == 2, text
        assert repo.git('status', '--porcelain').stdout == ''
        check = repo.run(CHECK, '--base', 'main', '--head', 'HEAD')
        assert check.returncode == 0, check.stdout + check.stderr
        cases += 1
    with tempfile.TemporaryDirectory(prefix='takibi-ckpt-rebase-') as tmp:
        repo = map_scenario(tmp, kept='topic kept')
        result = repo.run(HELPER, '--onto', 'main')
        assert result.returncode == 4, result.stdout + result.stderr
        assert MAP in result.stderr, result.stderr
        assert (repo.root / '.git/rebase-merge').exists(), 'non-stamp map conflict must stop'
        assert MAP in repo.git('diff', '--name-only', '--diff-filter=U').stdout.split()
        cases += 1
    report_pass('checkpoint-rebase-controls',
                f'{cases} scripted rebases; checkpoint-only conflict re-records, mixed conflict stops, '
                'stale branch review refused, clean rebase untouched, stamp-only model map '
                'conflict restamps, non-stamp model map conflict stops', cases=cases)


MAP = 'kernel/models/README.md'
# Stands in for the real checker: restamps every row with a digest of kernel/.
FAKE_MAP_CHECK = '''import hashlib, pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
digest = hashlib.sha256(b''.join(p.read_bytes() for p in sorted((root / 'kernel').glob('*.tkb')))).hexdigest()[:12]
readme = root / 'kernel/models/README.md'
if sys.argv[1:2] == ['--restamp']:
    readme.write_text(re.sub(r'`[0-9a-f]+` \\|$', '`' + digest + '` |', readme.read_text(), flags=re.M))
'''


# The real target builds both kernels' call-graph tables first (#987).
FAKE_MAKEFILE = ('model-map-restamp:\n'
                 '\t@python3 scripts/buildcheck_model_function_map.py --restamp q.tsv r.tsv\n')


def fake_stamp(root):
    import hashlib
    return hashlib.sha256(b''.join(p.read_bytes() for p in sorted((root / 'kernel').glob('*.tkb')))).hexdigest()[:12]


def map_text(stamp_a, stamp_b='bbbb', kept='kept'):
    return ('## M.tla\n\n| Action | Function | Kept | Dropped | Reviewed |\n| --- | --- | --- | --- | --- |\n'
            f'| `A` | `kernel_a` | {kept} | nothing | `{stamp_a}` |\n'
            f'| `B` | `kernel_b` | kept | nothing | `{stamp_b}` |\n')


def map_scenario(tmp, kept=None):
    """Both sides restamp row A in the commit that also rewrites the checkpoint."""
    repo = Repo(Path(tmp))
    repo.write('kernel/a.tkb', 'a0\n')
    repo.write('docs/evidence.tsv', 'measured\n')
    repo.write('scripts/buildcheck_model_function_map.py', FAKE_MAP_CHECK)
    repo.write('Makefile', FAKE_MAKEFILE)
    repo.write(MAP, map_text('aaaa'))
    repo.commit('base', review='base review')
    repo.git('switch', '-q', '-c', 'topic')
    repo.write('kernel/b.tkb', 'b1\n')
    repo.write(MAP, map_text('1111', kept=kept or 'kept'))
    repo.commit('topic work', review='topic review')
    repo.git('switch', '-q', 'main')
    repo.write('kernel/a.tkb', 'a1\n')
    repo.write(MAP, map_text('2222', kept='main kept' if kept else 'kept'))
    repo.commit('main work', review='main review')
    repo.git('switch', '-q', 'topic')
    return repo


if __name__ == '__main__':
    main()
