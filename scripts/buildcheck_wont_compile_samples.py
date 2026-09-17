#!/usr/bin/env python3
"""The defect catalog's sample programs, run through the real compiler.

`scripts/check_wont_compile_catalog.py` establishes that each entry in
`docs/wont-compile/` names a test case that exists. That is the paperwork.
This is the claim: the program printed under "Code that does not compile" is
rejected, with the diagnostic printed beside it, by the compiler this build
just produced -- and the program printed under "Code that does compile" is
accepted.

Why both halves are needed. The catalog's whole purpose is to be shown to
someone who does not yet believe the project's central claim, and the thing
they will do is copy a sample and run it. A compiler regression that stopped
rejecting one of these would leave every entry rendering exactly as before.
A named Alcotest case protects the behavior; it does not protect the page,
because the page transcribes the program and the message by hand.

The accepted samples are not decoration either. A check that only ever
demonstrates rejection cannot distinguish a working analysis from one that
rejects its neighbourhood, and that is precisely the difference a reader
cannot verify by looking.

This needs the built compiler, so it is a `buildcheck_` and runs from the
Makefile rule that builds it, not from a lane glob.

Usage: buildcheck_wont_compile_samples.py <takibi> [repo_root]
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

from check_wont_compile_catalog import CATALOG, load_entries
from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent

TARGET = "aarch64-none-elf"
WHITESPACE = re.compile(r"\s+")


def flatten(text: str) -> str:
    """Collapse whitespace so a wrapped diagnostic matches an unwrapped one.

    The compiler prints one long line. An entry wraps it, because a page with
    a 100-column line scrolls sideways on GitHub and in a slide. Comparing the
    two literally would force the documentation to be unreadable in order to
    be checkable, so the comparison gives up exact spacing -- and nothing
    else: the words, their order, and the arrows of the call path all still
    have to be there.
    """
    return WHITESPACE.sub(" ", text).strip()


def compile_sample(takibi: pathlib.Path, source: str, flags: list[str],
                   workdir: pathlib.Path, index: int) -> tuple[int, str]:
    path = workdir / f"sample{index}.tkb"
    path.write_text(source, encoding="utf-8")
    result = subprocess.run(
        [str(takibi), str(path), "--target", TARGET,
         "-o", str(workdir / f"sample{index}.o")] + flags,
        capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr


def main(takibi: pathlib.Path, root: pathlib.Path) -> int:
    if not takibi.exists():
        print(f"ERROR wont-compile-samples: {takibi} does not exist; this "
              "check must be handed a built compiler", file=sys.stderr)
        return 1

    structure: list[str] = []
    entries = load_entries(root / CATALOG, structure)
    # Structural complaints belong to the other check, which reports them with
    # its own wording. Repeating them here would make one broken entry fail
    # two members with two different explanations.
    if not entries:
        print(f"ERROR wont-compile-samples: no entries in {CATALOG}",
              file=sys.stderr)
        return 1

    failures: list[str] = []
    rejected = 0
    accepted = 0

    with tempfile.TemporaryDirectory() as tmp:
        workdir = pathlib.Path(tmp)
        index = 0

        for entry in entries:
            for source, diagnostic in entry.rejected:
                index += 1
                status, output = compile_sample(
                    takibi, source, entry.flags, workdir, index)
                if status == 0:
                    failures.append(
                        f"{entry.path.name}: a program shown as rejected "
                        "compiled successfully")
                    continue
                expected = flatten(diagnostic)
                if expected not in flatten(output):
                    failures.append(
                        f"{entry.path.name}: the diagnostic shown does not "
                        f"appear in the compiler's output\n"
                        f"  entry:    {expected}\n"
                        f"  compiler: {flatten(output)}")
                    continue
                rejected += 1

            for source in entry.accepted:
                index += 1
                status, output = compile_sample(
                    takibi, source, entry.flags, workdir, index)
                if status != 0:
                    failures.append(
                        f"{entry.path.name}: a program shown as accepted was "
                        f"rejected with: {flatten(output)}")
                    continue
                accepted += 1

    for failure in failures:
        print(f"FAIL wont-compile-samples: {failure}", file=sys.stderr)
    if failures:
        return 1

    report_pass(
        "wont-compile-samples",
        f"{rejected} programs are rejected with the diagnostic their entry "
        f"prints, and {accepted} are accepted, by the compiler this build "
        "produced",
        rejected=rejected,
        accepted=accepted,
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(1)
    sys.exit(main(
        pathlib.Path(sys.argv[1]),
        pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else REPO))
