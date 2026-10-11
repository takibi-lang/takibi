#!/usr/bin/env python3
"""Controls for check_agents_paths.py's existence test.

A path AGENTS.md names counts as present only when Git tracks it. An
untracked directory left on disk (build artifacts of a deleted tree) must
not satisfy it, which is the case the working-tree test once let through.
"""

import contextlib
import io
import pathlib
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
import check_agents_paths as check  # noqa: E402
from pass_line import report_pass  # noqa: E402


def run(root: pathlib.Path) -> int:
    check.ROOT = root
    check.AGENTS = root / "AGENTS.md"
    check.BUILD_CHECKS = root / "BUILD_CHECKS.md"
    # The fixture's own diagnostics and PASS line are expected, not news.
    with contextlib.redirect_stderr(io.StringIO()), \
            contextlib.redirect_stdout(io.StringIO()):
        return check.main()


def main() -> int:
    cases = 0
    with tempfile.TemporaryDirectory(prefix="takibi-agents-paths-") as tmp:
        root = pathlib.Path(tmp)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        # One inventoried check, so the verdict is about something.
        (root / "scripts").mkdir()
        (root / "scripts/check_fixture.py").write_text("")
        (root / "BUILD_CHECKS.md").write_text("| `check_fixture.py` |\n")
        (root / "AGENTS.md").write_text("See `gone/`, `kept/a.txt` and `kept/*.txt`.\n")
        (root / "gone").mkdir()
        (root / "gone/artifact.elf").write_text("untracked\n")
        (root / "kept").mkdir()
        (root / "kept/a.txt").write_text("tracked\n")
        subprocess.run(["git", "-C", str(root), "add", "AGENTS.md", "kept/a.txt",
                        "scripts/check_fixture.py"],
                       check=True)

        # An untracked directory on disk does not make `gone/` present.
        assert run(root) == 1, "an untracked directory satisfied a named path"
        cases += 1
        # Once tracked, the same tree passes: file, directory and glob forms.
        subprocess.run(["git", "-C", str(root), "add", "gone/artifact.elf"], check=True)
        assert run(root) == 0, "tracked paths were refused"
        cases += 1
        # A glob with no tracked member is refused.
        (root / "AGENTS.md").write_text("See `kept/*.md`.\n")
        assert run(root) == 1, "a glob with no tracked member was accepted"
        cases += 1
    report_pass("agents-paths controls",
                "an untracked directory and an empty glob are refused; tracked "
                "file, directory and glob paths pass", cases=cases)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
