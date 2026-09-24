#!/usr/bin/env python3
"""Every library named by a dune file has a package in dune-project.

The tracked Dune files state which findlib libraries the build needs. The
package stanza in dune-project maps those libraries to opam package names,
and Dune generates takibi.opam from that stanza for local setup and CI.

Findlib names and opam package names are not the same thing -- `llvm.target`
comes from `llvm`, `menhirLib` from `menhir`, and `ppx_deriving.show` from
`ppx_deriving` -- so the mapping is declared below rather than guessed. So is
the set that needs no package at all: the compiler's own libraries, and the
project's.

Exit code only (0 = pass, 1 = fail).
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
DUNE_PROJECT = ROOT / "dune-project"

LIBRARIES = ("libraries", "pps")

# findlib root name -> opam package that provides it.
PACKAGE_OF = {
    "llvm": "llvm",
    "menhirLib": "menhir",
    "ppx_deriving": "ppx_deriving",
    "alcotest": "alcotest",
    "bisect_ppx_ng": "bisect_ppx_ng",
    "dune-build-info": "dune-build-info",
}

# Needs no opam package: shipped with the compiler, or built here.
PROVIDED = {"unix", "str", "threads", "bytes", "takibi"}


def parse_sexps(text: str) -> list[object]:
    """Read the small S-expression subset used by dune-project."""
    tokens: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        if char.isspace():
            index += 1
            continue
        if char == ";":
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline + 1
            continue
        if char in "()":
            tokens.append(char)
            index += 1
            continue
        if char == '"':
            index += 1
            value: list[str] = []
            while index < len(text) and text[index] != '"':
                if text[index] == "\\" and index + 1 < len(text):
                    index += 1
                value.append(text[index])
                index += 1
            if index >= len(text):
                raise ValueError("unterminated string")
            tokens.append("".join(value))
            index += 1
            continue
        end = index
        while (end < len(text) and not text[end].isspace() and
               text[end] not in "();"):
            end += 1
        tokens.append(text[index:end])
        index = end

    def read_one(position: int) -> tuple[object, int]:
        if position >= len(tokens):
            raise ValueError("unexpected end of input")
        if tokens[position] != "(":
            if tokens[position] == ")":
                raise ValueError("unexpected closing parenthesis")
            return tokens[position], position + 1
        items: list[object] = []
        position += 1
        while position < len(tokens) and tokens[position] != ")":
            value, position = read_one(position)
            items.append(value)
        if position >= len(tokens):
            raise ValueError("unterminated list")
        return items, position + 1

    forms: list[object] = []
    position = 0
    while position < len(tokens):
        value, position = read_one(position)
        forms.append(value)
    return forms


def tracked_dune_files() -> list[pathlib.Path]:
    """Every dune file git knows about, which is the set that matters.

    Not `rglob("dune")`. That matched `_opam/bin/dune` on a CI runner --
    `ocaml/setup-ocaml` puts a local switch in the workspace -- and this check
    crashed decoding an ELF binary as UTF-8. Asking git is exact, needs no
    exclusion list to keep current, and cannot be surprised by the next
    directory something decides to create here.
    """
    try:
        listing = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z", "dune", "*/dune"],
            capture_output=True, check=True, timeout=60)
    except (OSError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", b"") or b""
        raise SystemExit(
            "FAIL ci-opam-deps: could not ask git which dune files are "
            f"tracked, so nothing can be compared: {error} "
            f"{detail.decode('utf-8', 'replace').strip()[:200]}") from None
    return [ROOT / name for name in
            listing.stdout.decode("utf-8").split("\0") if name]


def shown(path: pathlib.Path) -> str:
    """A path to put in a message, without a formatter that can raise."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def declared_libraries() -> set[str]:
    """Root findlib names every tracked dune file asks for."""
    names: set[str] = set()

    def visit(form: object) -> None:
        if not isinstance(form, list):
            return
        if form and form[0] in LIBRARIES:
            for value in form[1:]:
                if isinstance(value, str):
                    names.update(token.split(".", 1)[0]
                                 for token in value.split())
        elif form and form[0] == "backend":
            for value in form[1:]:
                if isinstance(value, str):
                    names.add(value.split(".", 1)[0])
        for value in form:
            visit(value)

    for path in tracked_dune_files():
        if not path.is_file():
            continue
        for form in parse_sexps(path.read_text(encoding="utf-8")):
            visit(form)
    return names


def package_dependencies() -> set[str]:
    """Package names in Takibi's consumed Dune package metadata."""
    try:
        forms = parse_sexps(DUNE_PROJECT.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        raise SystemExit(
            f"FAIL ci-opam-deps: cannot read {shown(DUNE_PROJECT)} as "
            f"Dune package metadata: {error}") from None

    package: list[object] | None = None
    for form in forms:
        if not isinstance(form, list) or not form or form[0] != "package":
            continue
        name = next((field[1] for field in form
                     if isinstance(field, list) and len(field) == 2 and
                     field[0] == "name"), None)
        if name == "takibi":
            package = form
            break
    if package is None:
        raise SystemExit(
            f"FAIL ci-opam-deps: {shown(DUNE_PROJECT)} has no package "
            "stanza named `takibi`, so its generated opam dependencies "
            "cannot be checked")

    depends = next((field for field in package
                    if isinstance(field, list) and field and
                    field[0] == "depends"), None)
    if depends is None:
        raise SystemExit(
            f"FAIL ci-opam-deps: package `takibi` in {shown(DUNE_PROJECT)} "
            "has no `(depends ...)` stanza")

    names: set[str] = set()
    for dependency in depends[1:]:
        if isinstance(dependency, str):
            names.add(dependency)
        elif isinstance(dependency, list) and dependency:
            name = dependency[0]
            if isinstance(name, str):
                names.add(name)
    return names


def main() -> int:
    try:
        declared = declared_libraries()
        dependencies = package_dependencies()
    except SystemExit as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, UnicodeError, ValueError) as error:
        print(f"FAIL ci-opam-deps: cannot parse tracked Dune metadata: "
              f"{error}", file=sys.stderr)
        return 1
    if not declared:
        print("FAIL ci-opam-deps: no dune file names a library, which cannot "
              "be right and would make this check pass about nothing",
              file=sys.stderr)
        return 1
    if not dependencies:
        print(f"FAIL ci-opam-deps: {shown(DUNE_PROJECT)} declares no package "
              "dependencies, so nothing can satisfy the dune libraries",
              file=sys.stderr)
        return 1

    missing = []
    unmapped = []
    for name in sorted(declared - PROVIDED):
        package = PACKAGE_OF.get(name)
        if package is None:
            unmapped.append(name)
        elif package not in dependencies:
            missing.append((name, package))

    for name in unmapped:
        print(f"FAIL ci-opam-deps: a dune file asks for `{name}`, which is "
              "neither in PACKAGE_OF nor in PROVIDED in this script. Say "
              "which opam package provides it, or that the compiler does.",
              file=sys.stderr)
    for name, package in missing:
        print(f"FAIL ci-opam-deps: a dune file asks for `{name}`, provided "
              f"by opam package `{package}`, which the `takibi` package in "
              f"{shown(DUNE_PROJECT)} does not declare in `(depends ...)`.",
              file=sys.stderr)

    if missing or unmapped:
        return 1

    report_pass(
        "ci-opam-deps",
        f"{len(declared)} Dune library/backend dependencies are declared in "
        "the generated package dependencies or provided by the compiler",
        dependencies=len(declared), packages=len(dependencies))
    return 0


if __name__ == "__main__":
    sys.exit(main())
