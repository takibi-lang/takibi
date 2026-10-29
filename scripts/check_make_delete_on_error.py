#!/usr/bin/env python3
"""A failed recipe may not leave its target behind (GitHub issue #1223).

During #1207 a check that runs inside the kernel main.o recipe after the
compile (buildcheck_ext2_mutation_guard) failed, but main.o stayed on disk,
so the next `make kernelbuild` found it up to date, skipped the check and
returned 0. The root Makefile declares .DELETE_ON_ERROR, which makes GNU
make delete a target whose recipe failed.

This control copies the root Makefile's .DELETE_ON_ERROR declaration into a
scratch makefile with one planted rule -- write the object, then fail a
post-compile check -- and runs make on it twice: both runs must fail. The
same rule without the declaration must pass on the second run, which shows
the control can tell the two apart.
"""

import pathlib
import re
import subprocess
import sys
import tempfile

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAKEFILE = ROOT / "Makefile"
DECLARATION = re.compile(r"^\.DELETE_ON_ERROR:\s*$", re.M)
PLANTED = ("main.o:\n"
           "\t@echo object > $@\n"
           "\t@echo 'planted post-compile check fails' >&2; exit 1\n")


def second_run_status(declaration: str) -> tuple[int, int]:
    with tempfile.TemporaryDirectory() as scratch:
        path = pathlib.Path(scratch) / "Makefile"
        path.write_text(declaration + PLANTED, encoding="ascii")
        runs = [subprocess.run(["make", "-s", "-C", scratch, "main.o"],
                               capture_output=True, text=True).returncode
                for _ in range(2)]
    return runs[0], runs[1]


def main() -> int:
    text = MAKEFILE.read_text(encoding="utf-8")
    found = DECLARATION.search(text)
    if found is None:
        print("FAIL make-delete-on-error: the root Makefile does not declare "
              ".DELETE_ON_ERROR: (#1223)", file=sys.stderr)
        return 1
    first, second = second_run_status(found.group(0) + "\n")
    if first == 0 or second == 0:
        print("FAIL make-delete-on-error: with the root Makefile's declaration, "
              f"a failed post-compile check let make return {first}, then {second}",
              file=sys.stderr)
        return 1
    bare_first, bare_second = second_run_status("")
    if bare_first == 0 or bare_second != 0:
        print("FAIL make-delete-on-error: without the declaration the planted "
              f"rule should fail once and then pass (got {bare_first}, "
              f"{bare_second}); the control no longer discriminates",
              file=sys.stderr)
        return 1
    report_pass("make-delete-on-error",
                "a failed post-compile check fails the next make too; without "
                ".DELETE_ON_ERROR the second make would pass",
                runs=4)
    return 0


if __name__ == "__main__":
    sys.exit(main())
