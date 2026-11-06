#!/usr/bin/env python3
"""GitHub issue #1391: name the untracked files a check run left behind.

qemu-aarch64 core files (#1386) accumulated in the worktree root during
linuxcheck, were ignored by every lane, and five were committed before
anyone noticed. allcheck and cicheck now take a snapshot of the worktree's
untracked, not-ignored files when they start and report the new ones when
they end:

    untracked_leaks.py snapshot DIR   write DIR/untracked.before
    untracked_leaks.py report DIR     print one NOTE line per new file

The report does not fail the run: a file the person created meanwhile in
the same worktree would otherwise fail an aggregate that is green. A lane
that writes into the tree should write under an ignored build directory or
be listed in .gitignore; the NOTE says which file to look at.
`--controls` checks the comparison on planted lists.
"""
import subprocess
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
BEFORE = "untracked.before"


def untracked() -> list[str]:
    done = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "--others", "--exclude-standard", "-z"],
        capture_output=True, timeout=60)
    if done.returncode != 0:
        return []
    return sorted(p for p in done.stdout.decode(errors="replace").split("\0") if p)


def new_files(before: list[str], after: list[str]) -> list[str]:
    seen = set(before)
    return [p for p in after if p not in seen]


def controls() -> int:
    cases = [
        ([], ["a.core"], ["a.core"]),
        (["keep.txt"], ["keep.txt"], []),
        (["keep.txt"], ["keep.txt", "x/qemu_p.core"], ["x/qemu_p.core"]),
        (["gone"], [], []),
    ]
    for before, after, want in cases:
        got = new_files(before, after)
        if got != want:
            print(f"FAIL  untracked-leaks control {before} -> {after}: got {got}, want {want}")
            sys.exit(1)
    return len(cases)


def main(argv: list[str]) -> int:
    if argv == ["--controls"]:
        n = controls()
        report_pass("untracked-leaks controls",
                    f"{n} planted before/after lists compared", cases=n)
        return 0
    if len(argv) != 2 or argv[0] not in ("snapshot", "report"):
        print("usage: untracked_leaks.py snapshot|report DIR | --controls", file=sys.stderr)
        return 2
    path = Path(argv[1]) / BEFORE
    if argv[0] == "snapshot":
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(p + "\n" for p in untracked()))
        return 0
    if not path.is_file():
        print(f"NOTE  untracked-leaks: no snapshot at {path}; nothing compared")
        return 0
    leaked = new_files(path.read_text().splitlines(), untracked())
    for p in leaked:
        print(f"NOTE  untracked-leaks: this run left an untracked file: {p} "
              f"(ignore it in .gitignore or write it under a build directory)")
    if not leaked:
        print("untracked-leaks: no new untracked file in the worktree")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
