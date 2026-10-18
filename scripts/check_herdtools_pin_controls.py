#!/usr/bin/env python3
"""Controls for check_herdtools_pin.py (#645)."""

from check_herdtools_pin import CI, DEVCONTAINER, problems, tree_texts
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    tree = tree_texts()
    assert not problems(tree), problems(tree)
    dev, ci = str(DEVCONTAINER), str(CI)
    failing = {
        "drifted CI pin": {**tree, ci: tree[ci].replace("herdtools7.7.58", "herdtools7.7.57")},
        "unpinned devcontainer": {**tree, dev: tree[dev].replace("herdtools7.7.58", "herdtools7")},
        "two pins in one file": {**tree, ci: tree[ci] + "\nopam install herdtools7.7.56\n"},
    }
    for name, texts in failing.items():
        cases.note()
        assert problems(texts), name
    report_pass("herdtools-pin controls",
                f"production passes and {cases.ran} drift shapes fail",
                controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
