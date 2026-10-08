#!/usr/bin/env python3
"""Compare linked kernel space against a base commit (GitHub issues #716/#717).

A space checkpoint needs a before/after measurement of both production
kernels. Doing it by hand meant a worktree, two builds, llvm-size, an
llvm-nm symbol diff and the image end, each typed again for every change.
This does exactly that and prints the table the evidence documents use:

    python3 scripts/space_delta.py [BASE]      # BASE defaults to origin/main

The working tree's kernels are built with `make kernelbuild-qemu
kernelbuild-rpi5`; the base is built in a temporary worktree, removed
afterwards. Symbol lines list every data/BSS symbol whose size changed,
appeared or disappeared. usable_ram_start says whether the image span, and
so the page reservations, moved.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = {"qemu": "kernel/build/qemu/kernel.elf",
           "rpi5": "kernel/build/rpi5/kernel.elf"}


def sh(args, cwd):
    subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.STDOUT, timeout=3600)


def build(tree):
    sh(["make", "kernelbuild-qemu", "kernelbuild-rpi5"], tree)


def sizes(elf):
    out = subprocess.run(["llvm-size-19", str(elf)], text=True, check=True,
                         stdout=subprocess.PIPE).stdout.splitlines()[1].split()
    return {"text": int(out[0]), "data": int(out[1]), "bss": int(out[2])}


def symbols(elf):
    out = subprocess.run(["llvm-nm-19", "-S", str(elf)], text=True, check=True,
                         stdout=subprocess.PIPE).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] in "bBdD":
            table[parts[3]] = int(parts[1], 16)
    out = subprocess.run(["llvm-nm-19", str(elf)], text=True, check=True,
                         stdout=subprocess.PIPE).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == "usable_ram_start":
            table["@usable_ram_start"] = int(parts[0], 16)
    return table


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
    build(ROOT)
    with tempfile.TemporaryDirectory(prefix="takibi-space-base-") as tmp:
        tree = Path(tmp) / "base"
        sh(["git", "worktree", "add", "-q", "--detach", str(tree), base], ROOT)
        try:
            build(tree)
            print(f"base {base} -> working tree")
            print("| | " + " | ".join(f"{t} base | {t} change" for t in TARGETS) + " |")
            rows = {}
            diffs = []
            for target, rel in TARGETS.items():
                before, after = tree / rel, ROOT / rel
                sb, sa = sizes(before), sizes(after)
                yb, ya = symbols(before), symbols(after)
                for key in ("text", "data", "bss"):
                    rows.setdefault(key, []).extend([sb[key], sa[key]])
                rows.setdefault("usable_ram_start", []).extend(
                    [hex(yb.get("@usable_ram_start", 0)),
                     hex(ya.get("@usable_ram_start", 0))])
                for name in sorted(set(yb) | set(ya)):
                    if name.startswith("@"):
                        continue
                    if yb.get(name) != ya.get(name):
                        diffs.append(f"{target}: {name} {yb.get(name)} -> {ya.get(name)}")
            for key, values in rows.items():
                print(f"| {key} | " + " | ".join(str(v) for v in values) + " |")
            print("data/BSS symbols changed:" if diffs else "no data/BSS symbol changed size")
            for line in diffs:
                print("  " + line)
        finally:
            sh(["git", "worktree", "remove", "--force", str(tree)], ROOT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
