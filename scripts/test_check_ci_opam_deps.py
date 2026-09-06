#!/usr/bin/env python3
"""Controls for the CI dependency link, including what it is allowed to read.

This check shipped without controls and broke CI within one run: it used
`rglob("dune")`, which on a runner matched `_opam/bin/dune` -- the dune
executable, since `ocaml/setup-ocaml` puts a local switch in the workspace --
and crashed decoding an ELF as UTF-8. The tree here has no `_opam`, so
nothing local disagreed.

The case that would have caught it is the last one below, and it is the reason
these exist: a check's SCAN SET is as much a part of it as its rule, and a
scan set is only pinned down by something that plants what must not be in it.
"""

import contextlib
import importlib.util
import io
import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_ci_opam_deps.py"


def load():
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location("check_ci_opam_deps",
                                                  CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(checker):
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        status = checker.main()
    return status, output.getvalue()


def planted(checker, workspace, dune_text, workflow_text):
    """Point the checker at one planted dune file and one planted workflow."""
    dune = workspace / "dune"
    dune.write_text(dune_text, encoding="ascii")
    workflow = workspace / "ci.yml"
    workflow.write_text(workflow_text, encoding="ascii")
    checker.WORKFLOW = workflow
    checker.tracked_dune_files = lambda: [dune]


WORKFLOW_OK = """
      - run: |
          opam install -y dune dune-build-info menhir ppx_deriving \\
                          alcotest bisect_ppx_ng
          opam install -y llvm.19-static
"""


def main() -> int:
    checker = load()

    # The repository itself passes, or nothing below means anything.
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
            ("a complete workflow",
             "(executable (name main) (libraries takibi dune-build-info))",
             WORKFLOW_OK, 0, "PASS ci-opam-deps"),
            # The failure that actually happened.
            ("a library the workflow does not install",
             "(executable (name main) (libraries takibi dune-build-info))",
             WORKFLOW_OK.replace("dune dune-build-info", "dune"),
             1, "does not install"),
            ("a library nobody mapped to a package",
             "(executable (name main) (libraries takibi yojson))",
             WORKFLOW_OK, 1, "neither in PACKAGE_OF nor in PROVIDED"),
            # Compiler-provided names need no package, and a versioned pin
            # still names its package.
            ("only compiler-provided libraries",
             "(executable (name main) (libraries takibi unix))",
             WORKFLOW_OK, 0, "PASS ci-opam-deps"),
            ("a ppx dependency",
             "(library (name t) (preprocess (pps ppx_deriving.show)))",
             WORKFLOW_OK, 0, "PASS ci-opam-deps"),
            # Both directions of "this check examined nothing".
            ("no dune file names a library",
             "(executable (name main))", WORKFLOW_OK, 1,
             "no dune file names a library"),
            ("a workflow that installs nothing",
             "(executable (name main) (libraries takibi dune-build-info))",
             "      - run: make\n", 1, "names no opam packages"),
        ]

        for label, dune_text, workflow_text, expected, needle in cases:
            planted(checker, workspace, dune_text, workflow_text)
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
    #
    # Deliberately NOT under _build. The version that broke CI already
    # excluded _build by name, so a probe there is protected by the very
    # filter whose insufficiency is the bug, and the control passes against
    # the broken code. It goes in a uniquely named directory at the top of
    # the workspace instead -- untracked, removed below, and never the real
    # `_opam`, which may be somebody's live switch.
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

    print("PASS ci-opam-deps controls: the repository passes, a missing "
          "package and an unmapped library are reported, compiler-provided "
          "names and ppx dependencies are accepted, an empty dune file and an "
          "empty workflow are refused, and an untracked binary named `dune` "
          "in the workspace is never opened")
    return 0


if __name__ == "__main__":
    sys.exit(main())
