#!/usr/bin/env python3
"""Check root guidance paths and the authoritative build-check inventory.

`AGENTS.md`'s directory map is deliberately coarse -- one entry per directory,
not per file -- because the per-file version silently went stale: by 2026-08-26
it omitted eight `lib/*.ml` files, nine of the ten `scripts/check_*.py` files,
and the entire `kernel/` tree, so a reader using it as an index would conclude
those did not exist.

Coarseness alone does not keep it honest, though, so this check enforces the
one direction that actually misleads a reader: **everything AGENTS.md names
must exist.** The reverse direction is deliberately NOT enforced -- requiring
every file to be documented is exactly what grew the section to 282 lines.

The `scripts/check_*.py` list lives in `docs/BUILD_CHECKS.md`; its whole value
is being complete, so every check must be named there.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENTS = ROOT / "AGENTS.md"
BUILD_CHECKS = ROOT / "docs/BUILD_CHECKS.md"

BACKTICKED = re.compile(r"`([^`\n]+)`")

# Build outputs are absent in a clean checkout, so naming one is not a lie.
GENERATED_SUFFIXES = (".o", ".elf", ".bin", ".img", ".map", ".inc", ".d")
GENERATED_PREFIXES = ("_build/", "kernel/build/")


def is_repo_path(token: str) -> bool:
    if "/" not in token:
        return False
    if token.startswith(("/", "http://", "https://", "~", "$", ".git/")):
        return False
    if any(c in token for c in " ,;()[]<>\"'"):
        return False
    if token.startswith(GENERATED_PREFIXES):
        return False
    if token.endswith(GENERATED_SUFFIXES):
        return False
    return True


def exists(token: str) -> bool:
    if "*" in token:
        # A glob is a claim that the shape has at least one member.
        return any(ROOT.glob(token))
    return (ROOT / token.rstrip("/")).exists()


def main() -> int:
    text = AGENTS.read_text(encoding="utf-8")

    missing = sorted({t for t in BACKTICKED.findall(text) if is_repo_path(t) and not exists(t)})
    checks_text = BUILD_CHECKS.read_text(encoding="utf-8")
    checked = sorted(p.name for p in (ROOT / "scripts").glob("check_*.py"))
    unnamed = [name for name in checked if name not in checks_text]

    for token in missing:
        print(f"ERROR: AGENTS.md names `{token}`, which does not exist", file=sys.stderr)
    for name in unnamed:
        print(
            f"ERROR: scripts/{name} is not named in docs/BUILD_CHECKS.md; "
            "add it to the build-check table",
            file=sys.stderr,
        )

    if missing or unnamed:
        return 1

    print(
        f"PASS agents-paths: {len(checked)} check scripts inventoried, "
        "every path in root AGENTS.md resolves"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
