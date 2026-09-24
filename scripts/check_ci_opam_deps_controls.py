#!/usr/bin/env python3
"""Controls for the link between dune files and Dune package metadata."""

import contextlib
import importlib.util
import io
import os
import shutil
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_ci_opam_deps.py"


def load():
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location("check_ci_opam_deps",
                                                  CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CASES = CaseCount()

DUNE_OK = """
(library
 (name core)
 (libraries takibi llvm.target llvm.analysis))
(instrumentation (backend bisect_ppx_ng))
(executable
 (name main)
 (libraries takibi dune-build-info))
(test
 (name test_core)
 (preprocess (pps ppx_deriving.show))
 (libraries takibi alcotest unix))
"""

PROJECT_OK = """
(lang dune 3.17)
(name takibi)
(package
 (name takibi)
 (depends
  (ocaml (>= 5.4.0))
  (llvm (= 19-static))
  dune-build-info
  menhir
  ppx_deriving
  (alcotest :with-test)
  (bisect_ppx_ng :dev)))
"""


def run(checker):
    CASES.note()
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        status = checker.main()
    return status, output.getvalue()


def planted(checker, workspace, dune_text, project_text):
    """Point the checker at one planted dune file and project metadata."""
    dune = workspace / "dune"
    dune.write_text(dune_text, encoding="ascii")
    project = workspace / "dune-project"
    project.write_text(project_text, encoding="ascii")
    checker.DUNE_PROJECT = project
    checker.tracked_dune_files = lambda: [dune]


def main() -> int:
    checker = load()

    status, output = run(checker)
    if status != 0:
        print(f"FAIL ci-opam-deps control: the repository failed\n{output}")
        return 1
    if "PASS ci-opam-deps" not in output:
        print(f"FAIL ci-opam-deps control: no verdict line\n{output}")
        return 1

    with tempfile.TemporaryDirectory() as name:
        workspace = Path(name)
        cases = [
            ("all library packages are declared", DUNE_OK, PROJECT_OK, 0,
             "PASS ci-opam-deps"),
            ("a findlib library package is missing", DUNE_OK,
             PROJECT_OK.replace("  dune-build-info\n", ""), 1,
             "dune-build-info"),
            ("the coverage backend package is missing", DUNE_OK,
             PROJECT_OK.replace("(bisect_ppx_ng :dev)", ""), 1,
             "bisect_ppx_ng"),
            ("a findlib library has no package mapping",
             "(executable (name main) (libraries takibi yojson))",
             PROJECT_OK, 1, "neither in PACKAGE_OF nor in PROVIDED"),
            ("only compiler and project libraries are used",
             "(executable (name main) (libraries takibi unix))",
             "(package (name takibi) (depends ocaml))", 0,
             "PASS ci-opam-deps"),
            ("a ppx findlib package is mapped", DUNE_OK,
             PROJECT_OK, 0, "PASS ci-opam-deps"),
            ("no dune file names a library", "(executable (name main))",
             PROJECT_OK, 1, "no dune file names a library"),
            ("no takibi package stanza exists", DUNE_OK,
             "(lang dune 3.17) (name another)", 1,
             "no package stanza named `takibi`"),
            ("the package has no depends field", DUNE_OK,
             "(package (name takibi))", 1, "has no `(depends ...)` stanza"),
        ]

        for label, dune_text, project_text, expected, needle in cases:
            planted(checker, workspace, dune_text, project_text)
            status, output = run(checker)
            if status != expected:
                print(f"FAIL ci-opam-deps control: {label} exited {status}, "
                      f"expected {expected}\n{output}")
                return 1
            if needle not in output:
                print(f"FAIL ci-opam-deps control: {label} did not report "
                      f"{needle!r}\n{output}")
                return 1

    # The scan set. An untracked binary named `dune` is what a local opam
    # switch puts in the workspace, and reading it is what broke CI. The
    # checker must not see it at all -- not decode it leniently, not skip it
    # after a failed decode, but never open it.
    probe = ROOT / f"_ci-opam-deps-control-{os.getpid()}"
    probe.mkdir(parents=True, exist_ok=True)
    try:
        (probe / "dune").write_bytes(b"\x7fELF\x02\x01\x01\x00\xb7\xc0 not text")
        checker = load()
        status, output = run(checker)
        if status != 0:
            print("FAIL ci-opam-deps control: an untracked binary named "
                  f"`dune` in the workspace broke the check\n{output}")
            return 1
    finally:
        shutil.rmtree(probe, ignore_errors=True)

    report_pass(
        "ci-opam-deps controls",
        "Dune package metadata covers tracked findlib dependencies, missing "
        "and unmapped packages are reported, compiler-provided libraries "
        "are accepted, malformed package metadata is refused, and an "
        "untracked binary named `dune` is never opened",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
