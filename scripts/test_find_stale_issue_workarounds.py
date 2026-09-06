#!/usr/bin/env python3
"""Controls for the stale-workaround worklist's matching.

The tool itself needs the network and is deliberately not part of any build,
but the part that decides WHAT to report is pure text matching and is the part
that rots: a pattern that stops matching turns a worklist into an empty page
that reads like good news.

So the matching runs here against planted comments, offline. The pair that
matters most is the third and fourth cases: "workaround (issue #15) needed
here" must match, and "no more manual workaround (issue #15) needed here" must
not, and the negation sits on a different line from the word it negates in
every real instance of it in this tree.
"""

import importlib.util
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "scripts" / "find_stale_issue_workarounds.py"


def load():
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location("finder", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def matches(finder, tree: Path, body: str) -> list:
    """Run the matcher over one planted file, with the tool rooted at tree."""
    (tree / "planted.tkb").write_text(body, encoding="utf-8")
    saved = finder.ROOT
    finder.ROOT = tree.parent
    try:
        return list(finder.findings([tree.name]))
    finally:
        finder.ROOT = saved


CASES = [
    # (label, comment body, how many issue references should be reported)
    ("a named workaround",
     "// GitHub issue #15: raw-pointer workaround needed here.\n", 1),
    ("a removed workaround, negated on the same line",
     "// no more workaround (issue #15) needed here.\n", 0),
    ("a removed workaround, negated on an earlier line",
     "// GitHub issue #217: indexes the field directly -- no more manual\n"
     "// `let`/raw-pointer-arithmetic workaround (issue #15) needed here.\n",
     0),
    ("an unfinished claim",
     "// This does not yet solve issue #89's actual shape.\n", 1),
    ("a TODO naming an issue",
     "// TODO: issue #42 would remove this branch.\n", 1),
    ("a settled rationale using a bare negation",
     "// GitHub issue #488: this RETURNS the pointer, so it cannot outlive\n"
     "// the proof, which is why the caller binds it.\n", 0),
    ("a settled rationale using 'is not'",
     "// GitHub issue #396: a slot address is not an arbitrary integer.\n", 0),
    ("the Pending variant, which is a type and not a status",
     "// GitHub issue #217: the begin step only produces Pending after\n"
     "// narrowing head to the array bound.\n", 0),
    ("an issue reference with no claim at all",
     "// GitHub issue #510 is that bug, measured as primary=0.\n", 0),
    ("a pending claim in code rather than a comment",
     'let s: str = "workaround for issue #15 not yet done";\n', 0),
    ("two issues on one unfinished line",
     "// not yet: issue #11 and issue #12 both have to land.\n", 2),
]


def main() -> int:
    finder = load()

    with tempfile.TemporaryDirectory() as name:
        tree = Path(name) / "kernel"
        tree.mkdir()
        for label, body, expected in CASES:
            found = matches(finder, tree, body)
            if len(found) != expected:
                print(f"FAIL stale-workarounds control: {label} produced "
                      f"{len(found)} finding(s), expected {expected}\n"
                      f"  body: {body!r}\n  found: {found}")
                return 1

        # A declared line stops being reported, and only that exact line.
        body = "// GitHub issue #15: raw-pointer workaround needed here.\n"
        finder.DECLARED[("kernel/planted.tkb",
                         "// GitHub issue #15: raw-pointer workaround needed "
                         "here.")] = "planted by the control"
        if matches(finder, tree, body):
            print("FAIL stale-workarounds control: a declared line was still "
                  "reported")
            return 1
        edited = "// GitHub issue #15: raw-pointer workaround still needed.\n"
        if not matches(finder, tree, edited):
            print("FAIL stale-workarounds control: editing a declared line "
                  "did not bring it back for review, so the declaration "
                  "outlives what it was about")
            return 1

    print("PASS stale-workarounds controls: a named workaround, an unfinished "
          "claim, a TODO and a two-issue line are reported; a removed "
          "workaround negated on either line, three settled rationales, a "
          "string literal and a declared line are not; and editing a declared "
          "line brings it back")
    return 0


if __name__ == "__main__":
    sys.exit(main())
