#!/usr/bin/env python3
"""Fail early when generated kernel depfiles name deleted prerequisites."""

import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Roots scanned RECURSIVELY: everything under them that ends in .d is a
# `takibi --emit-depfile` output.
DEPFILE_ROOTS = (ROOT / "kernel/build", ROOT / "kernel/arch/arm64/kernel")

# `_build` holds takibi depfiles at its TOP LEVEL only
# (_build/kernel-crash-snapshot-layout.gdb.d and its siblings, emitted by the
# Makefile's `--emit-depfile $@.d` rules). It is deliberately not recursed
# into: `_build/default/lib/.takibi.objs` holds two dozen depfiles that dune
# writes for OCaml modules, whose prerequisites are module names rather than
# repository paths, and reading those as paths would report every one of them
# stale.
#
# The gap this closes was measured rather than imagined. A `git stash` that
# removed a .tkb left `_build/kernel-crash-snapshot-layout.gdb.d` naming it,
# and `make kernelcheck-qemu` then failed with "No rule to make target" for
# four consecutive runs -- which read exactly like the lane being broken by
# the change under test, and came within one step of being recorded as a
# baseline measurement. This checker was already in the build and said PASS
# throughout, because the file was one directory outside the roots above.
DEPFILE_FLAT_ROOTS = (ROOT / "_build",)


def prerequisites(depfile: Path) -> list[str]:
    text = depfile.read_text().replace("\\\n", " ")
    _, separator, dependency_text = text.partition(":")
    if not separator:
        raise ValueError("missing ':' between target and prerequisites")
    return shlex.split(dependency_text, comments=False, posix=True)


def main() -> None:
    stale: list[tuple[Path, str]] = []
    malformed: list[tuple[Path, str]] = []
    depfiles = sorted(
        [path for root in DEPFILE_ROOTS if root.exists()
         for path in root.rglob("*.d")] +
        [path for root in DEPFILE_FLAT_ROOTS if root.exists()
         for path in root.glob("*.d")]
    )
    for depfile in depfiles:
        try:
            deps = prerequisites(depfile)
        except (ValueError, UnicodeError) as error:
            malformed.append((depfile, str(error)))
            continue
        for dependency in deps:
            path = Path(dependency)
            resolved = path if path.is_absolute() else ROOT / path
            if not resolved.exists():
                stale.append((depfile, dependency))

    if malformed or stale:
        print("ERROR: stale or malformed generated kernel depfiles detected:")
        for depfile, error in malformed:
            print(f"  {depfile.relative_to(ROOT)}: {error}")
        for depfile, dependency in stale:
            print(f"  {depfile.relative_to(ROOT)}: missing prerequisite {dependency}")
        print("Run `make clean` to remove generated dependency state, then rebuild.")
        sys.exit(1)

    print(f"PASS stale-depfiles: {len(depfiles)} generated depfiles have live prerequisites")


if __name__ == "__main__":
    main()
