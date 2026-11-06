#!/usr/bin/env python3
"""GitHub issue #1386: no qemu-user run may drop a core file in the tree.

qemu-aarch64 writes `qemu_<prog>_<time>_<pid>.core` into its current
directory when the guest dies by a core-dumping signal and RLIMIT_CORE
allows it. linuxcheck's #946 xfail probe dies that way by design, make
runs it from the worktree root, and five such files were committed on
2026-11-06.

This check refuses:

  * a recipe line in the Makefile that names `qemu-aarch64` outside a
    comment: recipes go through scripts/qemu_user.sh, which runs
    `ulimit -c 0` first;
  * a scripts/*.sh that names qemu-aarch64 and never runs `ulimit -c 0`;
  * a scripts/*.py that holds a "qemu-aarch64" string literal and never sets RLIMIT_CORE;
  * a .gitignore without `*.core`.

Planted texts with each defect are refused, so the check cannot pass by
matching nothing. Lexical: a qemu-user reached by another name is missed.
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
WRAPPER = "qemu_user.sh"
NAME_RE = re.compile(r"qemu-aarch64")


def makefile_errors(text: str, label: str) -> list[str]:
    errors = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.startswith("\t"):
            continue
        body = line.lstrip("\t@-+ ")
        if body.startswith("#"):
            continue
        if NAME_RE.search(body):
            errors.append(f"{label}:{n}: recipe runs qemu-aarch64 directly; "
                          f"use bash scripts/{WRAPPER} (core dumps off)")
    return errors


def code_lines(text: str) -> str:
    return "\n".join(l for l in text.splitlines()
                     if not l.lstrip().startswith("#"))


PY_NAME_RE = re.compile(r"[\"']qemu-aarch64")


def runs_qemu(text: str, suffix: str) -> bool:
    """A .sh names it in code; a .py names it as a string literal (a
    docstring mention is prose, not a run)."""
    if suffix == ".py":
        return bool(PY_NAME_RE.search(text))
    return bool(NAME_RE.search(code_lines(text)))


def script_errors(text: str, label: str, suffix: str) -> list[str]:
    code = code_lines(text)
    if not runs_qemu(text, suffix):
        return []
    if suffix == ".sh" and not re.search(r"\bulimit\s+-c\s+0\b", code):
        return [f"{label}: runs qemu-aarch64 without `ulimit -c 0`"]
    if suffix == ".py" and "RLIMIT_CORE" not in code:
        return [f"{label}: runs qemu-aarch64 without setting RLIMIT_CORE to 0"]
    return []


def gitignore_errors(text: str) -> list[str]:
    if "*.core" not in (l.strip() for l in text.splitlines()):
        return [".gitignore: no `*.core` pattern"]
    return []


def controls() -> int:
    planted = [
        ("make", makefile_errors("x:\n\t@got=$$(qemu-aarch64 a.elf)\n", "plant")),
        ("sh", script_errors("qemu-aarch64 \"$@\"\n", "plant.sh", ".sh")),
        ("sh-comment-ulimit", script_errors("# ulimit -c 0\nqemu-aarch64 x\n", "p.sh", ".sh")),
        ("py", script_errors("run(['qemu-aarch64'])\n", "plant.py", ".py")),
        ("gitignore", gitignore_errors("*.o\n")),
    ]
    for name, errs in planted:
        if not errs:
            print(f"FAIL  qemu-user-core-limit control {name} was not refused")
            sys.exit(1)
    clean = makefile_errors("x:\n\t@# qemu-aarch64 note\n\t@bash scripts/qemu_user.sh a\n", "ok")
    if clean:
        print(f"FAIL  qemu-user-core-limit clean control refused: {clean}")
        sys.exit(1)
    return len(planted)


def main() -> int:
    errors = makefile_errors((ROOT / "Makefile").read_text(), "Makefile")
    recipe_uses = sum(1 for l in (ROOT / "Makefile").read_text().splitlines()
                      if l.startswith("\t") and WRAPPER in l)
    scripts = 0
    for path in sorted((ROOT / "scripts").glob("*")):
        if path.suffix not in (".sh", ".py") or path.name == Path(__file__).name:
            continue
        text = path.read_text(errors="replace")
        if runs_qemu(text, path.suffix):
            scripts += 1
        errors += script_errors(text, f"scripts/{path.name}", path.suffix)
    errors += gitignore_errors((ROOT / ".gitignore").read_text())
    planted = controls()
    if errors:
        for e in errors:
            print(f"FAIL  {e}")
        return 1
    report_pass("qemu-user-core-limit",
                f"{recipe_uses} Makefile recipe lines use scripts/{WRAPPER}; "
                f"{scripts} scripts run qemu-aarch64 with core dumps off; "
                f"{planted} planted defects refused",
                recipe_uses=recipe_uses, scripts=scripts, planted=planted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
