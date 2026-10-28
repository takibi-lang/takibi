#!/usr/bin/env python3
"""Remove finished, fully landed worker worktrees (GitHub issue #1165).

Run by the coordinator (`make prune-worktrees`) after a worker reports done
and its work landed; deliberately not part of scripts/land.sh, because a green
land does not mean a worktree is finished (a worker may land one slice and go
on in the same worktree).

A worktree under <main worktree>/.claude/worktrees -- or only those named on
the command line, by directory name or path -- is removed, and its branch
deleted, only when all of these hold:

  * the branch has no patch outside the base (`git cherry <base> <branch>`
    prints no '+' line);
  * the tree has no tracked changes (`git status --untracked-files=no`);
  * no process has its cwd or an open file inside it (/proc/*/cwd, /proc/*/fd).

The worktree is unlocked first (agent worktrees are locked by the harness).
Its QEMU port block needs no step here: qemu_session_claim_block in
scripts/qemu_session_ports.sh drops a "<base>-wt-<name>" row whose worktree
no longer exists on the next claim (9fd64f7f).

Every worktree considered is printed as REMOVED or KEPT with the reason.
"""
import argparse
import os
import subprocess
import sys


def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r


def worktrees(repo):
    out = git(repo, "worktree", "list", "--porcelain").stdout
    entries, cur = [], {}
    for line in out.splitlines() + [""]:
        if not line:
            if cur:
                entries.append(cur)
            cur = {}
            continue
        key, _, val = line.partition(" ")
        cur[key] = val
    return entries


def busy_pids(path):
    """Pids (other than ours) whose cwd or an open fd lies inside path."""
    prefix = path.rstrip("/") + "/"
    me = os.getpid()
    found = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me:
            continue
        links = [f"/proc/{pid}/cwd"]
        try:
            links += [f"/proc/{pid}/fd/{fd}" for fd in os.listdir(f"/proc/{pid}/fd")]
        except OSError:
            pass
        for link in links:
            try:
                target = os.readlink(link)
            except OSError:
                continue
            if target == path or target.startswith(prefix):
                found.append(int(pid))
                break
    return found


def reason_to_keep(repo, wt, base):
    path = wt["worktree"]
    if not os.path.isdir(path):
        return "directory missing (run git worktree prune)"
    branch = wt.get("branch", "").removeprefix("refs/heads/")
    rev = branch or wt.get("HEAD", "")
    cherry = git(repo, "cherry", base, rev, check=False)
    if cherry.returncode != 0:
        return f"git cherry failed: {cherry.stderr.strip()}"
    unmerged = [l for l in cherry.stdout.splitlines() if l.startswith("+")]
    if unmerged:
        return f"{len(unmerged)} commit(s) not in {base}"
    st = git(path, "status", "--porcelain", "--untracked-files=no", check=False)
    if st.returncode != 0 or st.stdout.strip():
        return "tracked changes in the tree"
    pids = busy_pids(os.path.realpath(path))
    if pids:
        return "in use by pid " + ",".join(map(str, pids))
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*", help="worktree directory names or paths")
    ap.add_argument("--repo", default=".", help="any worktree of the repository")
    ap.add_argument("--base", default="origin/main")
    a = ap.parse_args()

    entries = worktrees(a.repo)
    main_path = entries[0]["worktree"]
    root = os.path.join(main_path, ".claude", "worktrees")
    candidates = [e for e in entries[1:]
                  if os.path.dirname(e["worktree"].rstrip("/")) == root]
    if a.names:
        wanted = {os.path.basename(os.path.abspath(n).rstrip("/")) for n in a.names}
        present = {os.path.basename(e["worktree"]) for e in candidates}
        for n in sorted(wanted - present):
            print(f"KEPT {n}: not a worktree under {root}")
        candidates = [e for e in candidates if os.path.basename(e["worktree"]) in wanted]

    removed = kept = 0
    for wt in candidates:
        name = os.path.basename(wt["worktree"])
        why = reason_to_keep(main_path, wt, a.base)
        if why:
            print(f"KEPT {name}: {why}")
            kept += 1
            continue
        git(main_path, "worktree", "unlock", wt["worktree"], check=False)
        # --force once: untracked build output (_build) would refuse a plain
        # remove; tracked changes were already ruled out above.
        r = git(main_path, "worktree", "remove", "--force", wt["worktree"], check=False)
        if r.returncode != 0:
            print(f"KEPT {name}: git worktree remove failed: {r.stderr.strip()}")
            kept += 1
            continue
        branch = wt.get("branch", "").removeprefix("refs/heads/")
        note = ""
        if branch:
            b = git(main_path, "branch", "-D", branch, check=False)
            note = (f", branch {branch} deleted" if b.returncode == 0 else
                    f", branch {branch} NOT deleted: {b.stderr.strip()}")
        print(f"REMOVED {name}{note}")
        removed += 1
    print(f"prune-worktrees: {removed} removed, {kept} kept")
    return 0


if __name__ == "__main__":
    sys.exit(main())
