#!/usr/bin/env python3
"""Every library the dune files name must be installed by the CI workflow.

The CI workflow installs opam packages by hand, and the build declares what it
needs in `dune` files. Those are two copies of one fact, and they drifted on
the very first run: `bin/dune` requires `dune-build-info`, the workflow did
not install it, and the job failed at `Library "dune-build-info" not found`.

What makes that worth a check rather than a shrug is who pays. Adding a
library to a `dune` file breaks CI for whoever pushes NEXT, not for whoever
added it, with an error about a package name that appears nowhere in their
change. This moves the failure to the person who caused it, at `langcheck`
time, with no network and no CI run.

Findlib names and opam package names are not the same thing -- `llvm.target`
comes from `llvm`, `menhirLib` from `menhir`, `ppx_deriving.show` from
`ppx_deriving` -- so the mapping is declared below rather than guessed. So is
the set that needs no package at all: the compiler's own libraries, and the
project's.

The reverse direction is deliberately NOT checked. The workflow may install
more than the build strictly needs -- `bisect_ppx_ng` is there for the
coverage target, which CI does not run -- and requiring that list to be
minimal would fail on a package somebody added for a good reason elsewhere.

Exit code only (0 = pass, 1 = fail).
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/ci.yml"

LIBRARIES = re.compile(r"\(libraries\s+([^)]*)\)", re.MULTILINE)
PPS = re.compile(r"\(pps\s+([^)]*)\)", re.MULTILINE)
# Continuation-aware: the install line wraps.
OPAM_INSTALL = re.compile(r"opam install -y ((?:[^\n\\]|\\\s*\n)*)")

# findlib root name -> opam package that provides it.
PACKAGE_OF = {
    "llvm": "llvm",
    "menhirLib": "menhir",
    "ppx_deriving": "ppx_deriving",
    "alcotest": "alcotest",
    "dune-build-info": "dune-build-info",
}

# Needs no opam package: shipped with the compiler, or built here.
PROVIDED = {"unix", "str", "threads", "bytes", "takibi"}


def shown(path: pathlib.Path) -> str:
    """A path to put in a message, without a formatter that can raise.

    `relative_to` throws when the path is outside the tree, which a control
    pointing this at a scratch file does. A diagnostic that crashes instead
    of printing is worse than no diagnostic.
    """
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def tracked_dune_files() -> list[pathlib.Path]:
    """Every dune file git knows about, which is the set that matters.

    Not `rglob("dune")`. That matched `_opam/bin/dune` on a CI runner --
    `ocaml/setup-ocaml` puts a local switch in the workspace -- and this check
    crashed decoding an ELF binary as UTF-8. Asking git is exact, needs no
    exclusion list to keep current, and cannot be surprised by the next
    directory something decides to create here.
    """
    listing = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z", "dune", "*/dune"],
        capture_output=True, check=True)
    return [ROOT / name for name in
            listing.stdout.decode("utf-8").split("\0") if name]


def declared_libraries() -> set[str]:
    """Root findlib names every tracked dune file asks for."""
    names: set[str] = set()
    for path in tracked_dune_files():
        if not path.is_file():
            # In the index but not on disk is git's business, not this
            # check's.
            continue
        text = path.read_text(encoding="utf-8")
        for match in LIBRARIES.findall(text) + PPS.findall(text):
            for token in match.split():
                token = token.strip()
                if token and not token.startswith(";"):
                    names.add(token.split(".", 1)[0])
    return names


def installed_packages() -> set[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    packages: set[str] = set()
    for match in OPAM_INSTALL.findall(text):
        for token in match.replace("\\", " ").split():
            # `llvm.19-static` pins a version; the package is the part before.
            packages.add(token.split(".", 1)[0])
    return packages


def main() -> int:
    if not WORKFLOW.is_file():
        print(f"FAIL ci-opam-deps: {shown(WORKFLOW)} does not exist, so "
              "nothing installs what the build needs", file=sys.stderr)
        return 1

    declared = declared_libraries()
    installed = installed_packages()
    if not declared:
        print("FAIL ci-opam-deps: no dune file names a library, which cannot "
              "be right and would make this check pass about nothing",
              file=sys.stderr)
        return 1
    if not installed:
        print("FAIL ci-opam-deps: the workflow names no opam packages, so "
              "either the install line moved or this check stopped reading it",
              file=sys.stderr)
        return 1

    missing = []
    unmapped = []
    for name in sorted(declared - PROVIDED):
        package = PACKAGE_OF.get(name)
        if package is None:
            unmapped.append(name)
        elif package not in installed:
            missing.append((name, package))

    for name in unmapped:
        print(f"FAIL ci-opam-deps: a dune file asks for `{name}`, which is "
              "neither in PACKAGE_OF nor in PROVIDED in this script. Say "
              "which opam package provides it, or that the compiler does.",
              file=sys.stderr)
    for name, package in missing:
        print(f"FAIL ci-opam-deps: a dune file asks for `{name}`, provided "
              f"by opam package `{package}`, which {shown(WORKFLOW)} does not "
              "install. CI would fail at 'Library not found' for whoever "
              "pushes next.", file=sys.stderr)

    if missing or unmapped:
        return 1

    report_pass(
        "ci-opam-deps",
        f"{len(declared)} libraries named by dune files are installed by the "
        "CI workflow or provided by the compiler",
        libraries=len(declared), packages=len(installed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
