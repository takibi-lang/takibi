#!/usr/bin/env python3
"""No script or recipe runs `dune build` under a wall-clock limit.

GitHub issue #641 (land of d470e8ef): scripts/fuzz_compiler.py built its
seeded-defect compiler with `subprocess.run(["dune", "build", ...],
timeout=120)`. With another worker building in parallel the build took
longer and the land went red with every lane otherwise green -- the third
load-induced timeout of that session. A build's duration follows the
machine's load; it is not a hang detector. Build first, untimed, as its own
step, and time only what can hang.

The rule, over tracked scripts/*.py, scripts/*.sh and the Makefile:
- Python: a call whose argument list names "dune" then "build" may not pass
  `timeout=` in the same call.
- Shell and Make recipes: a line may not run `timeout ... dune build`.
EXEMPT lists reviewed exceptions with the reason; it is empty.

Lexical; the file's own controls plant both shapes and require a refusal.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
PY_DUNE = re.compile(r"""["']dune["']\s*,\s*["']build["']""")
SH_TIMED = re.compile(r"\btimeout\b[^\n;|&]*\bdune\s+build\b")
EXEMPT: dict = {}


def call_extent(text: str, at: int) -> str:
    """The text of the innermost call `(`...`)` that encloses offset `at`."""
    depth = 0
    start = at
    while start > 0:
        start -= 1
        ch = text[start]
        if ch in ")]":
            depth += 1
        elif ch in "([":
            if depth == 0:
                if ch == "(":
                    break
                continue          # the list that holds the match
            depth -= 1
    depth = 0
    end = start
    while end < len(text):
        ch = text[end]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                return text[start:end + 1]
        end += 1
    return text[start:]


def problems_in(name: str, text: str) -> list:
    found = []
    if name.endswith(".py"):
        for match in PY_DUNE.finditer(text):
            if re.search(r"\btimeout\s*=", call_extent(text, match.start())):
                line = text.count("\n", 0, match.start()) + 1
                found.append(f"{name}:{line}: `dune build` with timeout=")
    else:
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0]
            if SH_TIMED.search(code):
                found.append(f"{name}:{number}: `timeout ... dune build`")
    return [f for f in found if f.split(":")[0] not in EXEMPT]


def control() -> bool:
    bad_py = ('r = subprocess.run(["dune", "build", "-j", "1", "x"], cwd=d,\n'
              '                   capture_output=True, timeout=120)\n')
    good_py = bad_py.replace(", timeout=120", "")
    other_py = ('subprocess.run(["make"], timeout=5)\n' + good_py
                + 'subprocess.run(["make"], timeout=5)\n')
    bad_sh = "\t@timeout 180s dune build bin/main.exe\n"
    return (len(problems_in("a.py", bad_py)) == 1 and not problems_in("a.py", good_py)
            and not problems_in("a.py", other_py)
            and len(problems_in("Makefile", bad_sh)) == 1
            and not problems_in("Makefile", "\t@dune build bin/main.exe\n"))


def main() -> int:
    if not control():
        print("FAIL untimed-dune-build: the control plants a timed dune build "
              "and the check did not refuse it (or refused the untimed one)",
              file=sys.stderr)
        return 1
    files = sorted((ROOT / "scripts").glob("*.py")) + \
        sorted((ROOT / "scripts").glob("*.sh")) + [ROOT / "Makefile"]
    problems = []
    for path in files:
        if path.name == pathlib.Path(__file__).name:
            continue
        problems.extend(problems_in(str(path.relative_to(ROOT)), path.read_text()))
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("FAIL untimed-dune-build: a build runs under a wall-clock limit; "
              "build untimed as its own step and time only what can hang (#641)",
              file=sys.stderr)
        return 1
    report_pass("untimed-dune-build",
                f"{len(files) - 1} script(s) and the Makefile run no dune build "
                "under a wall-clock limit", files=len(files) - 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
