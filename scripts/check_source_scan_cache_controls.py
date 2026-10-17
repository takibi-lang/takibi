#!/usr/bin/env python3
"""Controls for check_source_scan_cache.py (#808), and for source_scan.per_file."""

from check_source_scan_cache import REVIEWED, problems, tracked_modules
from pass_line import CaseCount, report_pass
from source_scan import FrozenMap, per_file


def main() -> int:
    cases = CaseCount()
    modules = tracked_modules()
    assert not problems(modules), problems(modules)
    target = "check_stopped_pool_inspection"
    uncached = modules[target].replace("from source_scan import per_file\n", "") \
                              .replace("@per_file\n", "")
    assert uncached != modules[target]
    failing = {
        # The #808 shape: a check its controls run in-process, uncached.
        "in-process check without per_file": {target: uncached},
        # The thrashing shape: a bounded functools cache, either spelling.
        "bounded lru_cache": {"check_model_function_map": modules["check_model_function_map"]
                              + "\nfrom functools import lru_cache\n"},
        "functools.lru_cache attribute": {"check_lock_rank_wrappers":
                                          modules["check_lock_rank_wrappers"]
                                          + "\nimport functools\n"
                                          "@functools.lru_cache(maxsize=8)\ndef f(t): return t\n"},
        "functools.cache": {"check_guest_syscalls_dispatched":
                            modules["check_guest_syscalls_dispatched"]
                            + "\nfrom functools import cache\n"},
        # A new in-process control of an unlisted uncached check.
        "new in-process controls": {"check_zz_controls": "import check_zz\n",
                                    "check_zz": "import pathlib\n"},
    }
    for name, change in failing.items():
        cases.note()
        assert problems({**modules, **change}), name
    cases.note()
    assert problems(modules, {**REVIEWED, "check_nothing": "x"}), "stale unimported"
    cases.note()
    assert problems(modules, {**REVIEWED, target: "x"}), "stale: uses helper"
    cases.note()
    # Transitive use counts: a check importing a module that uses per_file.
    assert not problems({**modules, "check_zz_controls": "import check_zz\n",
                         "check_zz": "import check_model_function_map\n"}), "transitive"

    # per_file: unbounded, and a mutable result is refused.
    calls = []

    @per_file
    def scan(text):
        calls.append(text)
        return tuple(text)
    for text in [str(i) for i in range(100)] * 2:
        scan(text)
    cases.note()
    assert len(calls) == 100, "per_file evicted an entry"

    @per_file
    def mutable(text):
        return [text]
    cases.note()
    try:
        mutable("x")
        raise AssertionError("per_file accepted a list result")
    except TypeError:
        pass
    frozen = per_file(lambda text: FrozenMap({text: 1}))("y")
    cases.note()
    try:
        frozen["z"] = 2
        raise AssertionError("FrozenMap accepted a write")
    except TypeError:
        pass
    report_pass("source-scan-cache controls",
                f"production passes and {cases.ran} uncached, bounded, stale or "
                f"mutable shapes behave as specified", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
