#!/usr/bin/env python3
"""Refuse a Makefile in which more than one rule runs `dune build`.

The Makefile states this as a rule and explains the cost:

    This must stay the ONLY rule in the repo that invokes `dune build`:
    ... so a second, independent invocation racing this one under `make -j`
    can't reintroduce the "Unexpected contents of build directory global
    lock file" corruption already hit once before

Nothing enforced it. On 2026-09-03 a recipe was given a sub-make so it could
hold a lock across its targets, that sub-make re-entered `$(TAKIBI)` outside
the kernel build lock, and `make allcheck` deadlocked with `dune build` asleep
on `_build/.lock` at 0% CPU. Three clones were broken until it was reverted.

Why a second invocation is not always wrong: the recursive makes under
`$(KERNEL_BUILD_LOCK_RUN)` set TAKIBI_KERNEL_BUILD_LOCK_HELD, and the
`$(TAKIBI)` rule is empty when that is set, so the inner make reuses the
compiler the outer one built. That is the shape a new recursive make has to
copy, and this check cannot see the difference -- so it checks the thing the
Makefile actually states, which is where the second invocation would come
from.
"""

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
MAKEFILE = REPO_ROOT / "Makefile"
EXPECTED_RULE = "$(TAKIBI)"
RULE = re.compile(r"^([^\t#\s][^:=]*):(?!=)")


def dune_invocations(text: str):
    """[(rule, line number, line)] for every recipe line running dune build."""
    found = []
    rule = None
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.startswith("\t"):
            match = RULE.match(line)
            if match:
                rule = match.group(1).strip()
            continue
        # A recipe line. Strip the tab and make's own prefixes first: a
        # recipe usually reads `\t@dune build`, and a pattern anchored at the
        # start or at whitespace does not see past the `@`. Missing that made
        # the first version of this check pass the very Makefile it was
        # written to reject.
        body = line.lstrip("\t").lstrip("@-+ ")
        # `dune test` and `dune exec` take the build directory lock too, but
        # the Makefile's rule is about `dune build`, so this checks what it
        # says rather than more.
        if re.search(r"(^|[;&|\s])dune\s+build(\s|$)", body):
            found.append((rule, number, line.strip()))
    return found


def main() -> int:
    found = dune_invocations(MAKEFILE.read_text(encoding="utf-8"))
    if not found:
        print("FAIL single-dune-invocation: no rule runs `dune build` at all; "
              "either the compiler is no longer built here or this check is "
              "looking at the wrong thing")
        return 1
    wrong = [entry for entry in found if entry[0] != EXPECTED_RULE]
    if len(found) > 1 or wrong:
        for rule, number, line in found:
            mark = "  <-- not the blessed rule" if rule != EXPECTED_RULE else ""
            print(f"ERROR\tMakefile:{number}: rule `{rule}` runs: {line}{mark}")
        print(
            f"FAIL single-dune-invocation: `dune build` must be run by "
            f"`{EXPECTED_RULE}` and by nothing else. A second invocation races "
            "the first for the dune build-directory lock. A recursive make "
            "that needs the compiler goes through $(KERNEL_BUILD_LOCK_RUN), "
            "which sets TAKIBI_KERNEL_BUILD_LOCK_HELD so the inner "
            f"`{EXPECTED_RULE}` does nothing."
        )
        return 1
    rule, number, _ = found[0]
    print(f"PASS single-dune-invocation: `dune build` runs from `{rule}` "
          f"(Makefile:{number}) and nowhere else")
    return 0


if __name__ == "__main__":
    sys.exit(main())
