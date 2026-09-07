#!/usr/bin/env python3
"""Controls for the pipefail/SIGPIPE check, in both directions.

The check passes on a clean tree and is expected to, which is the shape that
rots: a pattern that stops matching turns it into a check of nothing. So the
exact pipeline that cost four CI rounds is planted and required to be found,
along with the other early-exit consumers, and the forms that must NOT be
flagged are planted too -- reading to EOF, a producer that is not large, and a
script that does not set pipefail at all.
"""

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_pipefail_early_exit.py"

PIPEFAIL = "#!/usr/bin/env bash\nset -euo pipefail\n"

CASES = [
    # (label, script body, expected findings)
    ("the pipeline that broke CI",
     'A="$(llvm-nm-19 "$E" | awk \'$3 == "s" { print $1; exit }\')"\n', 1),
    ("the same pipeline reading to EOF",
     'A="$(llvm-nm-19 "$E" | awk \'$3 == "s" && !seen { print $1; seen = 1 }\')"\n',
     0),
    ("head after a large producer",
     'A="$(llvm-objdump-19 -d "$E" | head -1)"\n', 1),
    ("grep -q after a large producer",
     'llvm-readelf-19 -S "$E" | grep -q bss\n', 1),
    ("grep -m after a large producer",
     'llvm-nm-19 "$E" | grep -m 1 sym\n', 1),
    ("sed q after a large producer",
     'llvm-nm-19 "$E" | sed -n "1p;q"\n', 1),
    ("objdump, which is on the list too",
     'objdump -d "$E" | head -2\n', 1),
    # Not flagged, and each for its own reason.
    ("a large producer read to EOF by cat",
     'llvm-nm-19 "$E" | cat > /dev/null\n', 0),
    ("an early-exit consumer fed by a small producer",
     'echo hello | head -1\n', 0),
    ("a large producer with no pipe at all",
     'llvm-nm-19 "$E" > /tmp/out\n', 0),
]

NO_PIPEFAIL = ("#!/usr/bin/env bash\nset -eu\n"
               'A="$(llvm-nm-19 "$E" | awk \'{ print $1; exit }\')"\n')


def load():
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location("checker", CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def findings_for(checker, tree: Path, body: str) -> list:
    script = tree / "planted.sh"
    script.write_text(body, encoding="ascii")
    saved = checker.ROOT
    checker.ROOT = tree
    try:
        return list(checker.findings([script]))
    finally:
        checker.ROOT = saved


def main() -> int:
    checker = load()

    # The repository passes, or nothing below means anything.
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        status = checker.main()
    if status != 0 or "PASS pipefail-early-exit" not in output.getvalue():
        print(f"FAIL pipefail-early-exit control: the repository failed\n"
              f"{output.getvalue()}")
        return 1

    with tempfile.TemporaryDirectory() as name:
        tree = Path(name)
        for label, body, expected in CASES:
            found = findings_for(checker, tree, PIPEFAIL + body)
            if len(found) != expected:
                print(f"FAIL pipefail-early-exit control: {label} produced "
                      f"{len(found)} finding(s), expected {expected}\n"
                      f"  body: {body!r}\n  found: {found}")
                return 1

        # Without pipefail the producer's SIGPIPE is not the pipeline's
        # status, so the same line is not this check's business.
        if findings_for(checker, tree, NO_PIPEFAIL):
            print("FAIL pipefail-early-exit control: a script without "
                  "pipefail was flagged")
            return 1

        # A declared line stops being reported, and only that exact line.
        body = PIPEFAIL + 'A="$(llvm-nm-19 "$E" | head -1)"\n'
        checker.DECLARED[("planted.sh", 'A="$(llvm-nm-19 "$E" | head -1)"')] = \
            "planted by the control"
        if findings_for(checker, tree, body):
            print("FAIL pipefail-early-exit control: a declared line was "
                  "still reported")
            return 1
        edited = PIPEFAIL + 'A="$(llvm-nm-19 "$E" | head -2)"\n'
        if not findings_for(checker, tree, edited):
            print("FAIL pipefail-early-exit control: editing a declared line "
                  "did not bring it back for review")
            return 1

    print("PASS pipefail-early-exit controls: the pipeline that broke CI and "
          "four other early-exit consumers are found, reading to EOF and a "
          "small producer and a script without pipefail are not, and editing "
          "a declared line brings it back")
    return 0


if __name__ == "__main__":
    sys.exit(main())
