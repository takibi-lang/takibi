#!/usr/bin/env python3
"""Controls for check_text_search.py (GitHub issue #917).

The search shapes the compiler had before #917 are planted in a copy of a
source, in-process, and must be refused; a prefix test at offset 0, a
String.sub used as a value, and the shape inside a comment must not be.
"""

import sys

from check_text_search import problems, tracked_sources
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    sources = tracked_sources()
    failures = []
    cases.note()
    if problems(sources):
        failures.append(f"production does not pass: {problems(sources)}")
    target = "lib/region_builtin.ml"
    refused = {
        "moving offset in a while loop":
            "let f text i lp prefix = String.sub text !i lp = prefix\n",
        "recursive go":
            "let rec go i = i + m <= n && (String.sub text i m = sub || go (i + 1))\n",
        "not-equal search": "let g t j v = String.sub t !j (String.length v) <> v\n",
        "parenthesized offset": "let h s k n x = String.sub s (k + 1) n = x\n",
    }
    for name, line in refused.items():
        cases.note()
        if not problems({**sources, target: sources[target] + "\n" + line}):
            failures.append(f"{name}: accepted")
    accepted = {
        "prefix test at 0": "let p name n = String.sub name 0 n = \"__for_\"\n",
        "String.sub as a value":
            "let v text i n = Hashtbl.replace tbl (String.sub text i n) ()\n",
        "inside a comment": "(* was: String.sub text i m = sub *)\n",
        "physical equality": "let q s i n = String.sub s i n == s\n",
    }
    for name, line in accepted.items():
        cases.note()
        found = problems({**sources, target: sources[target] + "\n" + line})
        if found:
            failures.append(f"{name}: refused: {found}")
    for failure in failures:
        print(f"ERROR\ttext-search-controls: {failure}")
    if failures:
        print("FAIL text-search controls")
        return 1
    report_pass("text-search controls",
                "production passes; every pre-#917 search shape is refused, and a "
                "prefix test, a value, a comment and == pass", cases=cases.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
