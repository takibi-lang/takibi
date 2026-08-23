#!/usr/bin/env python3
"""Fail early when generated kernel depfiles name deleted prerequisites."""

import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPFILE_ROOTS = (ROOT / "kernel/build", ROOT / "kernel/arch/arm64/kernel")


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
        path for root in DEPFILE_ROOTS if root.exists()
        for path in root.rglob("*.d")
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
