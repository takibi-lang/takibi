#!/usr/bin/env python3
"""GitHub issue #1390: a timing-sensitive control has passed beside a CPU hog.

A control (`slowcheck_*`, `check_*_controls*`) that reads a clock, sleeps
or sets a timeout is timing-sensitive. Each one needs a row in
scripts/timing_controls_hogged.tsv whose sha256 matches the file as it is
now; scripts/run_beside_hog.py --record writes that row after the member
passed beside a CPU hog. An edited member therefore has to be run beside
the hog again before it lands, which is when a quiet-host assumption is
cheap to find (#1198's CPU control was not). A row for a file that no
longer exists or is no longer timing-sensitive is refused too, so the
table cannot drift. Lexical: a member that reaches a clock through a
helper module is missed.
"""
import hashlib
import os
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "scripts/timing_controls_hogged.tsv"
TIMING_RE = re.compile(
    r"time\.(?:time|monotonic|perf_counter)\(|date \+%s|(?<![\w-])sleep\s+[0-9$]|timeout=")


def timing_sensitive(text: str) -> bool:
    code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    return bool(TIMING_RE.search(code))


def members() -> list[Path]:
    scripts = ROOT / "scripts"
    found = set(scripts.glob("slowcheck_*.py")) | set(scripts.glob("slowcheck_*.sh"))
    found |= set(scripts.glob("check_*controls*.py")) | set(scripts.glob("check_*controls*.sh"))
    return sorted(found)


def read_table(text: str) -> dict[str, str]:
    rows = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise SystemExit(f"FAIL timing-controls-hogged: malformed row {line!r}")
        rows[fields[0]] = fields[1]
    return rows


def verdict(sensitive: dict[str, str], rows: dict[str, str]) -> list[str]:
    errors = []
    for name, digest in sorted(sensitive.items()):
        if name not in rows:
            errors.append(f"{name}: timing-sensitive and never run beside a CPU hog; "
                          f"run python3 scripts/run_beside_hog.py --record {name}")
        elif rows[name] != digest:
            errors.append(f"{name}: changed since it last passed beside a CPU hog; "
                          f"run python3 scripts/run_beside_hog.py --record {name}")
    for name in sorted(set(rows) - set(sensitive)):
        errors.append(f"{name}: row for a member that is gone or no longer timing-sensitive")
    return errors


def controls() -> int:
    assert timing_sensitive("t = time.monotonic()\n")
    assert timing_sensitive("sleep 0.2\n")
    assert timing_sensitive("run(x, timeout=5)\n")
    assert not timing_sensitive("# time.monotonic()\nprint(1)\n")
    assert verdict({"a.py": "1"}, {}), "an unlisted member passed"
    assert verdict({"a.py": "1"}, {"a.py": "2"}), "a stale row passed"
    assert verdict({}, {"a.py": "1"}), "an orphan row passed"
    assert not verdict({"a.py": "1"}, {"a.py": "1"}), "a current row was refused"
    return 8


def main() -> int:
    planted = controls()
    sensitive = {}
    for path in members():
        if path.name in (Path(__file__).name, os.environ.get("TAKIBI_HOG_MEMBER")):
            continue
        data = path.read_bytes()
        if timing_sensitive(data.decode(errors="replace")):
            sensitive[path.name] = hashlib.sha256(data).hexdigest()
    rows = read_table(TABLE.read_text() if TABLE.is_file() else "")
    errors = verdict(sensitive, rows)
    if errors:
        for error in errors:
            print(f"FAIL  {error}")
        return 1
    report_pass("timing-controls-hogged",
                f"{len(sensitive)} timing-sensitive controls passed beside a CPU hog "
                f"in their current form; {planted} planted cases judged",
                members=len(sensitive), planted=planted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
