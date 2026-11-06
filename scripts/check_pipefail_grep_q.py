#!/usr/bin/env python3
"""GitHub issue #1385: no shell script under pipefail pipes into a quiet grep.

Under `set -o pipefail`, `producer | grep -q PATTERN` fails when grep finds
its match and exits before the producer has finished writing: the producer
dies of SIGPIPE, the pipeline's status is 141, and a match reads as a miss.
It only happens when the producer is slow to write, so it shows under load.
found-by-policy.sh's `printf | grep -Eq 'git commit'` turned a closing
commit into a non-closing one in check_found_by_policy_controls.py inside
a loaded relayout-fragility run. The older lint caught only `grep -q`, not
`grep -Eq`.

Every scripts/**/*.sh and .githooks/* file that mentions pipefail is
scanned. Use a here-string (`grep -q PAT <<<"$text"`) or let grep read all
of its input (`... | grep PAT >/dev/null`). Planted lines are refused and
fixed forms accepted.
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
PIPE_INTO_QUIET_GREP = re.compile(
    r"(?<!\|)\|(?!\|)\s*(?:LC_ALL=C\s+)?grep\s+(?:-[A-Za-z]*q[A-Za-z]*|--quiet)\b")


def offending(text: str) -> list[int]:
    lines = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if PIPE_INTO_QUIET_GREP.search(line):
            lines.append(number)
    return lines


def controls() -> int:
    bad = ["printf '%s' \"$x\" | grep -q a", "cmd | grep -Eq 'a'", "    | grep -qx b \\",
           "cmd | LC_ALL=C grep -qP x", "cmd | grep --quiet x"]
    good = ["grep -Eq 'a' <<<\"$x\"", "cmd | grep a >/dev/null", "# cmd | grep -q a",
            "cmd | grep -c a", "[ x ] || grep -Eq a \"$log\""]
    for line in bad:
        assert offending(line), f"planted {line!r} was not refused"
    for line in good:
        assert not offending(line), f"fixed form {line!r} was refused"
    return len(bad) + len(good)


def main() -> int:
    planted = controls()
    files = [p for p in sorted((ROOT / "scripts").rglob("*.sh"))]
    files += [p for p in sorted((ROOT / ".githooks").glob("*")) if p.is_file()]
    scanned = 0
    errors = []
    for path in files:
        text = path.read_text(errors="replace")
        if "pipefail" not in text:
            continue
        scanned += 1
        for number in offending(text):
            errors.append(f"{path.relative_to(ROOT)}:{number}: a pipe into a quiet grep "
                          "under pipefail; use a here-string or `grep PAT >/dev/null`")
    if errors:
        for error in errors:
            print(f"FAIL  {error}")
        return 1
    report_pass("pipefail-grep-q",
                f"{scanned} pipefail shell scripts pipe into no quiet grep; "
                f"{planted} planted lines judged", scanned=scanned, planted=planted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
