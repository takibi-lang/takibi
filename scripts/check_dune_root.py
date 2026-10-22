#!/usr/bin/env python3
"""Every dune invocation pins its workspace root to its own tree.

GitHub issues #753 and #760: a worker worktree lives under
.claude/worktrees/ of the main checkout, and dune takes the OUTERMOST
dune-project (or dune-workspace) as its root. A bare `dune build` in a
worktree therefore built -- and locked, and wrote -- the main checkout's
_build. A committed dune-workspace does not fix it: once the main checkout
has one too, the outermost one still wins. Only `--root` / DUNE_ROOT does.

The rule, over tracked scripts/*.py, scripts/*.sh and the Makefile:
- Makefile: DUNE_ROOT is set with `override DUNE_ROOT := $(CURDIR)` and
  exported. `?=` would let an inherited DUNE_ROOT (a shell or make that ran
  in another checkout) point this tree's build elsewhere.
- Python: a call whose argument list starts "dune", <subcommand> must name
  DUNE_ROOT or --root inside the same call.
- Shell: a script that runs `dune <subcommand>` must export DUNE_ROOT.
EXEMPT lists reviewed exceptions with the reason.

The Makefile's $(TAKIBI) recipe also checks dynamically that dune wrote
this tree's _build/log. Lexical; the controls plant each shape.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUBCOMMANDS = r"(?:build|test|runtest|exec|rules|describe|clean|install)"
PY_DUNE = re.compile(r"""["']dune["']\s*,\s*["']""" + SUBCOMMANDS + r"""["']""")
SH_DUNE = re.compile(r"(^|[;&|\s])dune\s+" + SUBCOMMANDS + r"\b")
SH_PINNED = re.compile(r"^\s*export\s+DUNE_ROOT=", re.M)
MK_PINNED = re.compile(r"^override DUNE_ROOT := \$\(CURDIR\)\s*$", re.M)
MK_EXPORT = re.compile(r"^export DUNE_ROOT\s*$", re.M)
PY_PINNED = re.compile(r"DUNE_ROOT|--root")
EXEMPT = {
    "scripts/check_untimed_dune_build.py":
        "its controls hold dune calls as strings; it runs no dune",
    "scripts/check_fast_gate_no_spawn_controls.py":
        "its controls hold a dune call as a string; it runs no dune",
}


def call_extent(text: str, at: int) -> str:
    """The text of the innermost `(`...`)` call that encloses offset `at`."""
    depth = 0
    start = at
    while start > 0:
        start -= 1
        ch = text[start]
        if ch in ")]":
            depth += 1
        elif ch in "([":
            if depth == 0:
                if ch == "(":
                    break
                continue
            depth -= 1
    depth = 0
    for end in range(start, len(text)):
        ch = text[end]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                return text[start:end + 1]
    return text[start:]


def problems_in(name: str, text: str) -> list:
    found = []
    if name == "Makefile":
        if not MK_PINNED.search(text) or not MK_EXPORT.search(text):
            found.append("Makefile: no `override DUNE_ROOT := $(CURDIR)` "
                         "plus `export DUNE_ROOT`")
    elif name.endswith(".py"):
        for match in PY_DUNE.finditer(text):
            if not PY_PINNED.search(call_extent(text, match.start())):
                line = text.count("\n", 0, match.start()) + 1
                found.append(f"{name}:{line}: dune call without DUNE_ROOT/--root")
    else:
        code = "\n".join(l.split("#", 1)[0] for l in text.splitlines())
        if SH_DUNE.search(code) and not SH_PINNED.search(code):
            found.append(f"{name}: runs dune without `export DUNE_ROOT=`")
    return [f for f in found if f.split(":")[0] not in EXEMPT]


def control() -> bool:
    bad_py = 'subprocess.run(["dune", "build", "x"], cwd=d)\n'
    good_py = 'subprocess.run(["dune", "build", "x"], cwd=d,\n' \
              '               env={**os.environ, "DUNE_ROOT": d})\n'
    bad_sh = 'cd x\ndune test --force\n'
    good_sh = 'cd x\nexport DUNE_ROOT="$PWD"\ndune test --force\n'
    bad_mk = "DUNE_ROOT ?= $(CURDIR)\nexport DUNE_ROOT\n"
    good_mk = "override DUNE_ROOT := $(CURDIR)\nexport DUNE_ROOT\n"
    return (len(problems_in("a.py", bad_py)) == 1
            and not problems_in("a.py", good_py)
            and len(problems_in("a.sh", bad_sh)) == 1
            and not problems_in("a.sh", good_sh)
            and not problems_in("a.sh", "# dune build in a comment\n")
            and len(problems_in("Makefile", bad_mk)) == 1
            and not problems_in("Makefile", good_mk))


def main() -> int:
    if not control():
        print("FAIL dune-root: the control plants an unpinned dune root and "
              "the check did not refuse it (or refused a pinned one)",
              file=sys.stderr)
        return 1
    files = sorted((ROOT / "scripts").glob("*.py")) + \
        sorted((ROOT / "scripts").glob("*.sh")) + [ROOT / "Makefile"]
    files = [f for f in files if f.name != pathlib.Path(__file__).name]
    problems = []
    for path in files:
        problems.extend(problems_in(str(path.relative_to(ROOT)), path.read_text()))
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("FAIL dune-root: a dune invocation can take an enclosing "
              "checkout as its root and build that tree's _build (#760)",
              file=sys.stderr)
        return 1
    report_pass("dune-root",
                f"{len(files)} script(s) and the Makefile pin dune's root "
                "to their own tree", files=len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
