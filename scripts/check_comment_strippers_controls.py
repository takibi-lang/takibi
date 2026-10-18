#!/usr/bin/env python3
"""Controls for check_comment_strippers.py (GitHub issue #818).

Each stripper shape that existed in scripts/ before #818 is planted in a
copy of one check's text, in-process, and must be refused; the same shapes
in a Python comment, a split at a longer comment anchor, and source_scan
itself must not be; stale allow-list entries must be refused.
"""

import sys

from check_comment_strippers import ALLOWED, RAW_TEXT, problems, tracked_modules
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    modules = tracked_modules()
    failures = []
    cases.note()
    if problems(modules):
        failures.append(f"production does not pass: {problems(modules)}")
    target = "check_fallback_counters.py"
    refused = {
        "line split at //": 'code = line.split("//", 1)[0]\n',
        "line split at // with single quotes": "code = line.split('//')[0]\n",
        "partition at //": 'code = line.partition("//")[0]\n',
        "startswith //": 'if text.startswith("//", index):\n    pass\n',
        "startswith tuple": "if t.startswith(('//', '/*')):\n    pass\n",
        "line-comment regex": "code = re.sub(r'//[^\\n]*', '', text)\n",
        "dot-star regex": "code = re.sub(r'//.*', '', text)\n",
        "block-comment regex": "code = re.sub(r'/\\*.*?\\*/', '', text, flags=re.S)\n",
    }
    for name, line in refused.items():
        cases.note()
        if not problems({**modules, target: modules[target] + "\n" + line}):
            failures.append(f"{name}: accepted")
    accepted = {
        "a shape inside a Python comment": '# was: line.split("//")[0]\n',
        "a split at a longer comment anchor": 'tail = log.split("// Queue what fits", 1)[0]\n',
    }
    for name, line in accepted.items():
        cases.note()
        found = problems({**modules, target: modules[target] + "\n" + line})
        if found:
            failures.append(f"{name}: refused: {found}")
    cases.note()
    if problems({**modules, "source_scan.py": modules["source_scan.py"]
                 + '\nx = "a".split("//")\n'}):
        failures.append("source_scan itself was refused")
    cases.note()
    if not problems(modules, {**ALLOWED, "check_fallback_counters.py": "x"}):
        failures.append("an ALLOWED entry that strips nothing was accepted")
    cases.note()
    if not problems(modules, {**ALLOWED, "check_gone.py": "x"}):
        failures.append("an ALLOWED entry for a missing file was accepted")
    cases.note()
    if not problems(modules, ALLOWED, {**RAW_TEXT, "check_gone.py": "x"}):
        failures.append("a RAW_TEXT entry for a missing file was accepted")
    for failure in failures:
        print(f"ERROR\tcomment-strippers-controls: {failure}")
    if failures:
        print("FAIL comment-strippers controls")
        return 1
    report_pass("comment-strippers controls",
                "production passes; every pre-#818 stripper shape is refused, a "
                "commented shape, a longer anchor and source_scan pass, and stale "
                "allow-list entries are refused", cases=cases.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
