#!/usr/bin/env python3
"""Controls for the defect catalog's two checks.

A check that has never been seen to fail is a check nobody has evidence
about. Both members guarded here exist to refuse a catalog that lies, and
neither one's PASS means anything until the failures it is supposed to catch
have been planted and caught.

Each scenario builds a complete, valid catalog and then breaks exactly one
thing. That is what makes a negative control faithful: a fixture that is
malformed in some second way passes for the wrong reason, and then keeps
passing after the check it was written for has stopped working.

`buildcheck_wont_compile_samples.py` needs a compiler, which the fast gate
does not have. Its decision logic is controlled here with a stub standing in
for one -- so what is established is that the runner believes a rejection,
notices a missing one, notices a changed diagnostic, and notices an accepted
program being refused. That the real compiler behaves as the catalog says is
the buildcheck's own job, from the rule that builds it.

Usage: check_wont_compile_catalog_controls.py
Exit code only (0 = pass, 1 = fail).
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

SCRIPTS = pathlib.Path(__file__).resolve().parent
REPO = SCRIPTS.parent
CATALOG_CHECK = SCRIPTS / "check_wont_compile_catalog.py"
SAMPLE_CHECK = SCRIPTS / "buildcheck_wont_compile_samples.py"

ENTRY = """# 0007. A widget that is not proven

| Field | Value |
| --- | --- |
| Status | Enforced |
| Check | type error, widget checker |
| Test case | `widget: an unproven widget is rejected` |
| Introduced | 2026-01-01, commit `0000000` ("Widgets") |

![A widget](assets/0007-an-unproven-widget.svg)

## The defect

A widget nobody proved.

## Code that does not compile

```takibi
fn bad_widget() {}
```

```text
the widget is not proven
  bad_widget -> widget
```

## Code that does compile

```takibi
fn good_widget() {}
```
"""

INDEX = """# Programs that will not compile

## Entries

| # | Defect | Status |
| --- | --- | --- |
| [0007](0007-an-unproven-widget.md) | A widget that is not proven | Enforced |
"""

SUITE = '''let () =
  Alcotest.test_case "widget: an unproven widget is rejected" `Quick
    (expect_type_error "the widget is not proven" "fn bad_widget() {}")
'''

# The stub prints its message on one line; the fixture entry above wraps it
# over two. That difference is deliberate: it is the whitespace-collapsing
# comparison under control, not merely the happy path.
STUB = """#!/usr/bin/env python3
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
if "bad_widget" in source:
    print("the widget is not proven bad_widget -> widget", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"""

STUB_ACCEPTS_EVERYTHING = """#!/usr/bin/env python3
import sys
sys.exit(0)
"""

STUB_OTHER_MESSAGE = """#!/usr/bin/env python3
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
if "bad_widget" in source:
    print("some unrelated failure", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"""

STUB_REJECTS_EVERYTHING = """#!/usr/bin/env python3
import sys
print("the widget is not proven bad_widget -> widget", file=sys.stderr)
sys.exit(1)
"""

# Only rejects when the entry's `Compile with` flag actually reached it. If
# the flag were dropped, the rejected sample would compile and the runner
# would say so -- which is what makes this a test of the flag and not of the
# stub.
STUB_NEEDS_FLAG = """#!/usr/bin/env python3
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
if "bad_widget" in source and "--forbid-trap" in sys.argv:
    print("the widget is not proven bad_widget -> widget", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"""

FLAG_ROW = "| Compile with | `--forbid-trap` |\n"


def build_root(tmp: pathlib.Path) -> pathlib.Path:
    """A complete, valid catalog, which every scenario starts from."""
    root = tmp / "root"
    catalog = root / "docs" / "wont-compile" / "assets"
    catalog.mkdir(parents=True)
    (root / "test").mkdir(parents=True)

    (catalog.parent / "0007-an-unproven-widget.md").write_text(ENTRY)
    (catalog.parent / "README.md").write_text(INDEX)
    (catalog / "0007-an-unproven-widget.dot").write_text("digraph w {}\n")
    (catalog / "0007-an-unproven-widget.svg").write_text("<svg></svg>\n")
    (root / "test" / "test_takibi.ml").write_text(SUITE)
    return root


def run_catalog(root: pathlib.Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(CATALOG_CHECK), str(root)],
        capture_output=True, text=True, check=False)


def run_samples(root: pathlib.Path, stub: pathlib.Path
                ) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SAMPLE_CHECK), str(stub), str(root)],
        capture_output=True, text=True, check=False)


def write_stub(tmp: pathlib.Path, name: str, body: str) -> pathlib.Path:
    path = tmp / name
    path.write_text(body)
    path.chmod(0o755)
    return path


class Controls:
    def __init__(self) -> None:
        self.cases = CaseCount()
        self.failures: list[str] = []

    def expect_pass(self, what: str,
                    result: subprocess.CompletedProcess) -> None:
        self.cases.note()
        if result.returncode != 0:
            self.failures.append(
                f"{what}: expected success, got {result.returncode}\n"
                f"{result.stdout}{result.stderr}")

    def expect_fail(self, what: str, result: subprocess.CompletedProcess,
                    wanted: str) -> None:
        self.cases.note()
        if result.returncode == 0:
            self.failures.append(f"{what}: the defect was not caught")
        elif wanted not in result.stderr:
            self.failures.append(
                f"{what}: caught, but not for the stated reason; "
                f"expected text {wanted!r} in:\n{result.stderr}")


def main() -> int:
    controls = Controls()

    with tempfile.TemporaryDirectory() as raw:
        tmp = pathlib.Path(raw)

        controls.expect_pass("the repository itself", run_catalog(REPO))

        root = build_root(tmp)
        controls.expect_pass("a valid catalog", run_catalog(root))

        entry = root / "docs" / "wont-compile" / "0007-an-unproven-widget.md"
        index = root / "docs" / "wont-compile" / "README.md"
        assets = root / "docs" / "wont-compile" / "assets"
        suite = root / "test" / "test_takibi.ml"
        original = entry.read_text()

        def restore() -> None:
            entry.write_text(original)
            index.write_text(INDEX)
            suite.write_text(SUITE)

        suite.write_text(SUITE.replace(
            "an unproven widget is rejected", "a renamed case"))
        controls.expect_fail("a renamed test case", run_catalog(root),
                             "is not in test_takibi.ml")
        restore()

        entry.write_text(original.replace("| Status | Enforced |",
                                          "| Status | Probably |"))
        controls.expect_fail("an invented status", run_catalog(root),
                             "it must be Enforced")
        restore()

        entry.write_text(original.replace(
            "| Test case | `widget: an unproven widget is rejected` |\n", ""))
        controls.expect_fail("a missing Test case row", run_catalog(root),
                             "has no `Test case` row")
        restore()

        entry.write_text(original.replace("# 0007. A widget",
                                          "# 0008. A widget"))
        controls.expect_fail("a heading numbered differently from its file",
                             run_catalog(root), "a citation can only follow")
        restore()

        entry.write_text(original.replace(
            "```text\nthe widget is not proven\n  bad_widget -> widget\n```\n\n",
            ""))
        controls.expect_fail("a rejected program with no diagnostic",
                             run_catalog(root),
                             "not followed by a ```text block")
        restore()

        entry.write_text(original.replace(
            "## Code that does compile\n\n```takibi\nfn good_widget() {}\n```\n",
            "## Code that does compile\n\nNone yet.\n"))
        controls.expect_fail("an entry that never shows acceptance",
                             run_catalog(root), "no accepted program found")
        restore()

        (assets / "0007-an-unproven-widget.svg").unlink()
        controls.expect_fail("a missing figure", run_catalog(root),
                             "0007-an-unproven-widget.svg is missing")
        (assets / "0007-an-unproven-widget.svg").write_text("<svg></svg>\n")

        (assets / "0007-an-unproven-widget.dot").unlink()
        controls.expect_fail("a figure whose source is gone",
                             run_catalog(root), "can be looked at but never")
        (assets / "0007-an-unproven-widget.dot").write_text("digraph w {}\n")

        # The figure trap, planted the way it actually happened: a shared
        # rank naming one node inside the cluster and one outside it.
        dot = assets / "0007-an-unproven-widget.dot"
        good = dot.read_text()
        dot.write_text("""digraph w {
  written [label="outside"];
  subgraph cluster_rejected {
    label="rejected at compile time";
    declared [label="inside"];
  }
  board [label="below"];
  { rank=same; written; declared; }
  declared -> board;
}
""")
        controls.expect_fail("a rank that spans a cluster boundary",
                             run_catalog(root),
                             "graphviz will evict the clustered node")
        # The same figure with the rank set wholly inside the cluster is
        # legal, and a check that refused it would ban the layout 0001 uses.
        dot.write_text("""digraph w {
  subgraph cluster_rejected {
    label="rejected at compile time";
    a [label="one"];
    b [label="two"];
    { rank=same; a; b; }
  }
  board [label="below"];
  a -> board;
}
""")
        controls.expect_pass("a rank wholly inside one cluster",
                             run_catalog(root))
        dot.write_text(good)

        (assets / "0009-orphan.dot").write_text("digraph o {}\n")
        controls.expect_fail("a figure no entry claims", run_catalog(root),
                             "no entry claims this figure")
        (assets / "0009-orphan.dot").unlink()

        index.write_text(INDEX.replace(
            "| [0007](0007-an-unproven-widget.md) | A widget that is not "
            "proven | Enforced |\n", ""))
        controls.expect_fail("an entry missing from the index",
                             run_catalog(root), "is not in the index table")
        restore()

        index.write_text(INDEX.replace("(0007-an-unproven-widget.md)",
                                       "(0007-a-different-file.md)"))
        controls.expect_fail("an index row linking the wrong file",
                             run_catalog(root), "links 0007-a-different-file")
        restore()

        index.write_text(INDEX.replace("| Enforced |", "| Partial |"))
        controls.expect_fail("an index that disagrees about status",
                             run_catalog(root), "and the entry says")
        restore()

        index.write_text(INDEX + "| [0011](0011-a-ghost.md) | A ghost "
                                 "| Enforced |\n")
        controls.expect_fail("an index row for an entry that does not exist",
                             run_catalog(root), "which does not exist")
        restore()

        entry.write_text(original.replace(
            "| Check | type error, widget checker |\n",
            "| Check | type error, widget checker |\n" + FLAG_ROW))
        controls.expect_pass("an entry that names compiler flags",
                             run_catalog(root))
        stub = write_stub(tmp, "stub_flag.py", STUB_NEEDS_FLAG)
        controls.expect_pass("flags reaching the compiler",
                             run_samples(root, stub))
        restore()
        # The same stub against the same entry with its flag row removed: the
        # rejected program now compiles. That is what the flag was doing, and
        # it is the only reading under which the scenario above means anything.
        controls.expect_fail("the same stub once the flag row is gone",
                             run_samples(root, stub),
                             "shown as rejected compiled successfully")

        entry.write_text(original.replace(
            "| Check | type error, widget checker |\n",
            "| Check | type error, widget checker |\n"
            "| Compile with | --forbid-trap |\n"))
        controls.expect_fail("an unbackticked flag list", run_catalog(root),
                             "is not backticked")
        restore()

        entry.write_text(original.replace(
            "| Check | type error, widget checker |\n",
            "| Check | type error, widget checker |\n"
            "| Compile with | `with the trap flag` |\n"))
        controls.expect_fail("prose where flags belong", run_catalog(root),
                             "contains a token that is not one")
        restore()

        stub = write_stub(tmp, "stub_compiler.py", STUB)
        controls.expect_pass("samples against a faithful stub",
                             run_samples(root, stub))

        stub = write_stub(tmp, "stub_accepts.py", STUB_ACCEPTS_EVERYTHING)
        controls.expect_fail("a compiler that stopped rejecting",
                             run_samples(root, stub),
                             "shown as rejected compiled successfully")

        stub = write_stub(tmp, "stub_other.py", STUB_OTHER_MESSAGE)
        controls.expect_fail("a rejection with a different message",
                             run_samples(root, stub),
                             "does not appear in the compiler's output")

        stub = write_stub(tmp, "stub_rejects.py", STUB_REJECTS_EVERYTHING)
        controls.expect_fail("a compiler that rejects the accepted program",
                             run_samples(root, stub),
                             "shown as accepted was rejected")

        controls.expect_fail("a sample runner handed no compiler",
                             run_samples(root, tmp / "absent"),
                             "must be handed a built compiler")

    for failure in controls.failures:
        print(f"FAIL wont-compile-catalog controls: {failure}",
              file=sys.stderr)
    if controls.failures:
        return 1

    report_pass(
        "wont-compile-catalog controls",
        f"{controls.cases.ran} claims -- the repository and a valid fixture "
        "pass; a renamed test case, an invented status, a missing field, a "
        "misnumbered heading, an unpinned sample, an entry that never shows "
        "acceptance, a missing figure, a figure without its source, an "
        "unclaimed figure, a rank constraint that would silently empty a "
        "cluster (while one wholly inside it is allowed), four ways the "
        "index and the entries can "
        "disagree, an unbackticked flag list and prose where flags belong "
        "are each refused; compiler flags an entry names reach the "
        "compiler, and dropping them is noticed; and the sample runner "
        "notices a "
        "rejection that stopped happening, one with a different message, an "
        "accepted program that was refused, and a compiler that is not there",
        cases=controls.cases.ran,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
