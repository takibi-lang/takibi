#!/usr/bin/env python3
"""Positive and faithful negative controls for the conflict-marker check.

A check that only ever passes is indistinguishable from one that is not
running, and this one is expected to pass on every healthy tree -- which is
exactly the shape that rots unnoticed. So each marker git can write is
planted in a scratch repository and the check is required to find it.
"""

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_no_conflict_markers.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_no_conflict_markers",
                                                  CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scratch_repo(directory, content):
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
    (directory / "doc.md").write_text(content, encoding="utf-8")
    subprocess.run(["git", "-C", str(directory), "add", "-A"], check=True)
    return directory


def run(checker, directory):
    """The checker's status, with its output captured.

    A control that plants a conflict on purpose makes the checker print a
    real-looking FAIL. Letting that reach the build log teaches a reader to
    scroll past the word, which is the opposite of what the check is for.
    """
    saved = sys.argv
    sys.argv = [str(CHECKER), str(directory)]
    captured = io.StringIO()
    try:
        with contextlib.redirect_stdout(captured), \
                contextlib.redirect_stderr(captured):
            return checker.main()
    finally:
        sys.argv = saved


def main():
    checker = load_checker()
    clean = "# Doc\n\nOrdinary prose.\n\nA setext heading\n=======\n\nmore.\n"

    with tempfile.TemporaryDirectory() as name:
        root = Path(name)
        if run(checker, scratch_repo(root / "clean", clean)) != 0:
            print("FAIL no-conflict-markers control: a clean tree failed")
            return 1

        # `=======` alone must NOT trip the check: it is a legal Markdown
        # setext underline, and the clean fixture above contains one.
        for label, marker in (("ours", checker.OPEN_MARKER),
                              ("theirs", checker.CLOSE_MARKER),
                              ("diff3 base", checker.BASE_MARKER)):
            body = f"# Doc\n\n{marker} HEAD\nleft\n=======\nright\n"
            planted = scratch_repo(root / f"c{label.replace(' ', '')}", body)
            if run(checker, planted) == 0:
                print(f"FAIL no-conflict-markers control: the {label} marker "
                      f"was not detected")
                return 1

        # An untracked conflicted file is git's business, not this check's.
        untracked = scratch_repo(root / "untracked", clean)
        (untracked / "stray.md").write_text(
            f"{checker.OPEN_MARKER} HEAD\n", encoding="utf-8")
        if run(checker, untracked) != 0:
            print("FAIL no-conflict-markers control: an UNTRACKED conflicted "
                  "file was reported")
            return 1

    print("PASS no-conflict-markers controls: clean tree, three markers "
          "detected, setext underline ignored, untracked file ignored")
    return 0


if __name__ == "__main__":
    sys.exit(main())
