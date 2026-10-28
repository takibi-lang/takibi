#!/usr/bin/env python3
"""Controls for scripts/prune_worktrees.py (GitHub issue #1165), in a
temporary Git repository: a clean landed worktree is removed with its branch;
one with an unmerged commit, a dirty tracked file, or a live process whose cwd
is inside it is kept; naming worktrees limits what is considered."""
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from pass_line import report_pass

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prune_worktrees.py")
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")


def run(cwd, *cmd):
    return subprocess.run(cmd, cwd=cwd, env=ENV, check=True,
                          capture_output=True, text=True).stdout


def write(path, text, mode="w"):
    with open(path, mode) as f:
        f.write(text)


def main():
    failures = []
    checked = [0]

    def expect(cond, what):
        checked[0] += 1
        if not cond:
            failures.append(what)

    with tempfile.TemporaryDirectory() as tmp:
        origin = os.path.join(tmp, "origin.git")
        repo = os.path.join(tmp, "repo")
        run(tmp, "git", "init", "-q", "--bare", "-b", "main", origin)
        run(tmp, "git", "clone", "-q", origin, repo)
        write(os.path.join(repo, "f"), "0\n")
        run(repo, "git", "add", "f")
        run(repo, "git", "commit", "-qm", "init")
        run(repo, "git", "push", "-q", "origin", "HEAD:main")
        run(repo, "git", "fetch", "-q", "origin")
        wtroot = os.path.join(repo, ".claude", "worktrees")

        def add(name):
            p = os.path.join(wtroot, name)
            run(repo, "git", "worktree", "add", "-q", "--lock", "-b", name, p, "origin/main")
            return p

        landed = add("landed")
        write(os.path.join(landed, "f"), "landed\n", "a")
        run(landed, "git", "commit", "-qam", "landed")
        run(landed, "git", "push", "-q", "origin", "HEAD:main")
        write(os.path.join(landed, "untracked"), "x\n")  # build output does not keep it
        unmerged = add("unmerged")
        write(os.path.join(unmerged, "g"), "g\n")
        run(unmerged, "git", "add", "g")
        run(unmerged, "git", "commit", "-qm", "unmerged")
        dirty = add("dirty")
        write(os.path.join(dirty, "f"), "dirty\n", "a")
        busy = add("busy")
        other = add("other")
        run(repo, "git", "fetch", "-q", "origin")

        sleeper = subprocess.Popen(["sleep", "60"], cwd=busy)
        try:
            out = run(repo, sys.executable, SCRIPT, "--repo", repo,
                      "landed", "unmerged", "dirty", "busy", "nosuch")
        finally:
            sleeper.kill()
            sleeper.wait()
        print(out, end="")

        branches = run(repo, "git", "branch", "--format=%(refname:short)").split()
        expect("REMOVED landed, branch landed deleted" in out
               and not os.path.exists(landed) and "landed" not in branches,
               "clean landed worktree removed with its branch")
        for name, why in (("unmerged", "1 commit(s) not in origin/main"),
                          ("dirty", "tracked changes in the tree"),
                          ("busy", f"in use by pid {sleeper.pid}"),
                          ("nosuch", "not a worktree under")):
            expect(f"KEPT {name}: {why}" in out, f"{name} kept with its reason")
        for name in ("unmerged", "dirty", "busy"):
            expect(name in branches and os.path.isdir(os.path.join(wtroot, name)),
                   f"{name} worktree and branch still present")
        expect("other" not in out and os.path.isdir(other),
               "a worktree not named is not considered")

        out = run(repo, sys.executable, SCRIPT, "--repo", repo)
        print(out, end="")
        expect("REMOVED busy" in out and "REMOVED other" in out,
               "idle landed worktrees removed when no names are given")
        expect("KEPT unmerged" in out and "KEPT dirty" in out,
               "unmerged and dirty kept again")
        expect(os.path.isdir(repo), "main worktree never considered")

    for f in failures:
        print(f"FAIL prune-worktrees control: {f}", file=sys.stderr)
    if failures:
        return 1
    report_pass("prune-worktrees-controls",
                f"{checked[0]} expectations: landed removed; unmerged, dirty, busy kept",
                expectations=checked[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
