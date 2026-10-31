#!/usr/bin/env python3
"""Which fast-lane checks read layout rather than code (GitHub issue #1311)?

Before `takibi fmt` formats the kernel, every check must keep its verdict on
the same program laid out differently. This copies the tracked tree twice,
applies to every tracked .tkb of one copy a layout change no compiler token
sees (a blank line after each statement line, 4-space indentation made
2-space), and runs each scripts/check_* member in both. A member that passes
in the plain copy and fails in the relaid one reads layout; a member that fails
in both says nothing here (it needs something the copy lacks).

A planted member that reads layout must be reported, so a relayout that stopped
reaching the source cannot pass. A member that fails in both copies is refused
too: this would otherwise pass about fewer checks than it names.

It is slowcheck rather than a fast-lane member because it runs that whole lane
twice. A pass is evidence about this one relayout, not about the formatter's
eventual style, and it covers no buildcheck_* (those need a kernel).

  usage: slowcheck_relayout_fragility.py [--keep DIR] [MEMBER ...]
"""

import argparse
import concurrent.futures
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

from pass_line import report_pass
from source_scan import code_only

ROOT = pathlib.Path(__file__).resolve().parent.parent
INDENT = re.compile(r"^((?:    )+)(?=\S)")
PLANTED = "planted_layout_reader.py"
PLANT = """import pathlib, sys
text = pathlib.Path("kernel/kernel/process.tkb").read_text()
sys.exit(text.count(";\\n\\n") * 2 > text.count(";\\n"))
"""


def relaid(text: str) -> str:
    """The same tokens: only blank lines and leading spaces change."""
    code = code_only(text).split("\n")
    out = []
    for line, skeleton in zip(text.split("\n"), code):
        out.append(INDENT.sub(lambda m: "  " * (len(m[1]) // 4), line))
        if skeleton.rstrip().endswith(";"):
            out.append("")
    return "\n".join(out)


def git(cwd, *args):
    return subprocess.run(("git",) + args, cwd=cwd, check=True, text=True,
                          capture_output=True).stdout


def copy_tree(destination: pathlib.Path, relay: bool):
    """A committed copy of the tracked files: some checks ask git for the list."""
    for name in git(ROOT, "ls-files", "-z").split("\0"):
        source = ROOT / name
        if not name or not source.is_file():
            continue
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
        if relay and name.endswith(".tkb"):
            target.write_text(relaid(source.read_text(encoding="utf-8")), encoding="utf-8")
    git(destination, "init", "-q")
    git(destination, "add", "-A")
    git(destination, "-c", "user.name=relayout", "-c", "user.email=relayout@takibi.invalid",
        "commit", "-q", "-m", "copy")


def run(tree: pathlib.Path, member: str):
    runner = "bash" if member.endswith(".sh") else "python3"
    try:
        done = subprocess.run((runner, f"scripts/{member}"), cwd=tree, text=True, errors="replace",
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    return done.returncode == 0, done.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", type=pathlib.Path, help="write each failure's output here")
    parser.add_argument("members", nargs="*")
    options = parser.parse_args()
    members = options.members or sorted(
        p.name for p in (ROOT / "scripts").iterdir()
        if p.name.startswith("check_") and p.suffix in (".py", ".sh"))
    if not members:
        raise SystemExit("FAIL relayout-fragility: no members")
    members.append(PLANTED)
    with tempfile.TemporaryDirectory(prefix="relayout") as scratch:
        plain = pathlib.Path(scratch) / "plain"
        moved = pathlib.Path(scratch) / "relaid"
        copy_tree(plain, False)
        copy_tree(moved, True)
        for tree in (plain, moved):
            (tree / "scripts" / PLANTED).write_text(PLANT, encoding="ascii")
        changed = sum(1 for p in moved.rglob("*.tkb")
                      if p.read_bytes() != (plain / p.relative_to(moved)).read_bytes())
        if not changed:
            raise SystemExit("FAIL relayout-fragility: the relayout changed no file")
        with concurrent.futures.ThreadPoolExecutor(max(2, (os.cpu_count() or 4) // 2)) as pool:
            before = list(pool.map(lambda m: run(plain, m), members))
            after = list(pool.map(lambda m: run(moved, m), members))
    fragile, unknown = [], []
    for member, (base_ok, _), (moved_ok, output) in zip(members, before, after):
        if not base_ok:
            unknown.append(member)
        elif not moved_ok:
            fragile.append(member)
            if options.keep:
                options.keep.mkdir(parents=True, exist_ok=True)
                (options.keep / f"{member}.log").write_text(output, encoding="utf-8")
    if PLANTED not in fragile:
        print("FAIL relayout-fragility: the planted layout reader was not reported")
        return 1
    fragile.remove(PLANTED)
    members.remove(PLANTED)
    for member in unknown:
        print(f"  fails unrelaid too: {member}")
    for member in fragile:
        print(f"  reads layout: {member}")
    if fragile or unknown:
        print(f"FAIL relayout-fragility: of {len(members)} members, {len(fragile)} read "
              f"layout and {len(unknown)} fail in a plain copy")
        return 1
    report_pass("relayout-fragility",
                f"{len(members)} fast-lane members keep their verdict on {changed} relaid files; "
                "a planted layout reader was reported", members=len(members))
    return 0


if __name__ == "__main__":
    sys.exit(main())
