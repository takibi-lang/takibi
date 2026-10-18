#!/usr/bin/env python3
"""Controls for check_herdtools_pin.py (#645)."""

from check_herdtools_pin import BUILD, CI, DEVCONTAINER, problems, tree_texts
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    tree = tree_texts()
    assert not problems(tree), problems(tree)
    dev, build, ci = str(DEVCONTAINER), str(BUILD), str(CI)
    guard = "if: steps.herd7-cache.outputs.cache-hit != 'true'\n"
    failing = {
        "drifted CI pin": {**tree, build: tree[build].replace("herdtools7.7.58", "herdtools7.7.57")},
        "unpinned devcontainer": {**tree, dev: tree[dev].replace("herdtools7.7.58", "herdtools7")},
        "two pins in one file": {**tree, build: tree[build] + "\n# herdtools7.7.56\n"},
        # The shape that broke main on 2026-10-18.
        "per-run opam install": {**tree, ci: tree[ci].replace(
            "opam install -y --deps-only --with-test .",
            "opam install -y --deps-only --with-test .\n            opam install -y herdtools7")},
        "unguarded build": {**tree, ci: tree[ci].replace(guard, "")},
        "second build step": {**tree, ci: tree[ci] + "\n      - run: bash scripts/build_herd7.sh /tmp/h\n"},
        "key ignores the pin": {**tree, ci: tree[ci].replace(
            "hashFiles('scripts/build_herd7.sh')", "hashFiles('dune-project')")},
        "build outside the cache": {**tree, ci: tree[ci].replace(
            "build_herd7.sh /home/runner/herd7", "build_herd7.sh /home/runner/elsewhere")},
        "HERD7 unset": {**tree, ci: tree[ci].replace("HERD7: /home/runner/herd7/bin/herd7", "")},
    }
    for name, texts in failing.items():
        assert texts != tree, f"control {name} changed nothing"
        cases.note()
        assert problems(texts), name
    report_pass("herdtools-pin controls",
                f"production passes and {cases.ran} drift shapes fail",
                controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
