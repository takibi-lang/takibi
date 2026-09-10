#!/usr/bin/env python3
"""Controls for the PASS-line guard, in both directions.

This is the check that exists because a mechanism reporting PASS about
nothing reads exactly like one reporting PASS about something. A control that
only proves the healthy tree passes would be the same defect one level up, so
every rule is also planted and required to fail, with the diagnostic checked
rather than only the exit code.

The scratch scripts are never imported, only parsed, so they can name a
`report_pass` that is not importable from where they sit.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_pass_line_counts.py"

COMPLIANT = '''\
from pass_line import report_pass


def main():
    files = sorted(__import__("pathlib").Path(".").glob("*"))
    report_pass("scratch", f"{len(files)} files", files=len(files))
'''


def run(directory):
    """The checker's exit status and combined output for a scripts dir."""
    result = subprocess.run(
        [sys.executable, str(CHECKER), str(directory)],
        capture_output=True, text=True,
    )
    return result.returncode, result.stdout + result.stderr


def scratch(root, name, body):
    directory = root / name
    directory.mkdir()
    for filename, text in body.items():
        (directory / filename).write_text(text, encoding="ascii")
    return directory


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def expect(label, directory, status, needle):
    CASES.note()
    code, output = run(directory)
    if code != status:
        print(f"FAIL pass-line-counts control: {label} exited {code}, "
              f"expected {status}\n{output}")
        return False
    if needle not in output:
        print(f"FAIL pass-line-counts control: {label} did not report "
              f"{needle!r}\n{output}")
        return False
    return True


def helper_controls():
    """`report_pass` itself must refuse a zero count, and print otherwise."""
    for label, kwargs in (("zero", {"files": 0}),
                          ("negative", {"files": -1}),
                          ("no count", {})):
        script = (
            "import sys; sys.path.insert(0, %r)\n"
            "from pass_line import report_pass\n"
            "report_pass('scratch', 'a verdict', **%r)\n"
            % (str(ROOT / "scripts"), kwargs)
        )
        result = subprocess.run([sys.executable, "-c", script],
                                capture_output=True, text=True)
        if result.returncode == 0:
            print(f"FAIL pass-line-counts control: report_pass accepted a "
                  f"{label} count")
            return False
        if "PASS" in result.stdout:
            print(f"FAIL pass-line-counts control: report_pass printed PASS "
                  f"for a {label} count")
            return False

    result = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, %r)\n"
         "from pass_line import report_pass\n"
         "report_pass('scratch', '3 files', files=3)\n" % str(ROOT / "scripts")],
        capture_output=True, text=True)
    if result.returncode != 0 or result.stdout != "PASS scratch: 3 files\n":
        print("FAIL pass-line-counts control: report_pass did not print the "
              f"PASS line for a nonzero count: {result.stdout!r}")
        return False

    return True


def main():
    # The tree itself must pass, or the controls below prove nothing about
    # the check that actually runs in the build.
    if not expect("the repository", ROOT / "scripts", 0,
                  "PASS pass-line-counts:"):
        return 1

    with tempfile.TemporaryDirectory() as name:
        root = Path(name)

        cases = (
            ("a compliant check", {"check_ok.py": COMPLIANT}, 0,
             "PASS pass-line-counts:"),
            ("a hand-printed PASS line",
             {"check_bare.py": COMPLIANT +
              '    print("PASS scratch: it all looks fine")\n'},
             1, "prints its own PASS line"),
            ("report_pass with no count",
             {"check_none.py":
              'from pass_line import report_pass\n\n\n'
              'def main():\n    report_pass("scratch", "a verdict")\n'},
             1, "names no count"),
            ("a literal count",
             {"check_literal.py":
              'from pass_line import report_pass\n\n\n'
              'def main():\n    report_pass("scratch", "one", files=1)\n'},
             1, "is the literal 1"),
            ("counts hidden behind **kwargs",
             {"check_splat.py":
              'from pass_line import report_pass\n\n\n'
              'def main():\n    counts = {"files": 2}\n'
              '    report_pass("scratch", "two", **counts)\n'},
             1, "through **kwargs"),
            # `stream` steers the report; it is not a count, and a check
            # passing only that has still asserted nothing.
            ("a stream with no count beside it",
             {"check_stream.py":
              'import sys\n\nfrom pass_line import report_pass\n\n\n'
              'def main():\n    report_pass("scratch", "a verdict", '
              'stream=sys.stderr)\n'},
             1, "names no count"),
            ("a check with no verdict at all",
             {"check_silent.py": 'def main():\n    return 0\n'},
             1, "never calls pass_line.report_pass"),
            # The declared exemption must still be consulted: the batched
            # UART report's per-case rows are results, not verdicts.
            ("the declared per-case PASS row",
             {"buildcheck_suite_output.py": COMPLIANT +
              '    print(f"PASS\\t{files}")\n'},
             0, "PASS pass-line-counts:"),
        )

        for index, (label, body, status, needle) in enumerate(cases):
            directory = scratch(root, f"case{index}", body)
            if not expect(label, directory, status, needle):
                return 1

    if not helper_controls():
        return 1

    report_pass(
        "pass-line-counts controls",
        "the repository passes, seven planted defects are caught, the "
        "declared exemption is honoured, and report_pass refuses a "
        "zero, negative, and missing count",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
