#!/usr/bin/env python3
"""Controls for check_source_scan_cache.py (#808), and for source_scan.per_file
and source_scan.code_only (#815)."""

from check_source_scan_cache import REVIEWED, problems, tracked_modules
from pass_line import CaseCount, report_pass
from source_scan import (FrozenMap, code_only, code_skeleton, compact,
                         per_file, py_code_only, sh_code_only)


def main() -> int:
    cases = CaseCount()
    modules = tracked_modules()
    assert not problems(modules), problems(modules)
    target = "check_stopped_pool_inspection"
    uncached = modules[target].replace("from source_scan import code_only, per_file\n",
                                       "from source_scan import code_only\n") \
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
        # GitHub issue #815: code_only caches nothing; importing it alone
        # is not per_file use.
        "imports only code_only": {"check_zz_controls": "import check_zz\n",
                                   "check_zz": "from source_scan import code_only\n"},
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
    # code_only (#815): comments blanked in place, literals kept.
    for source, want in [
        ("a(); // b()\n", "a();       \n"),
        ("a(); /* b()\nc() */ d();", "a();       \n       d();"),
        ('s("http://x"); // y', 's("http://x");     '),
        ("x = '\"'; // \"y", "x = '\"';      "),
        ('t("/* not */"); u();', 't("/* not */"); u();'),
    ]:
        cases.note()
        got = code_only(source)
        assert got == want and len(got) == len(source), (source, got)
    # GitHub issue #818: the other comment rules, each length-preserving
    # but compact, whose output is a hash input.
    for function, source, want in [
        (code_skeleton, 'f("{") /* } */ g(\'(\');', 'f(   )         g(   );'),
        (code_skeleton, "a(); // {\nb();", "a();     \nb();"),
        (py_code_only, 'x = "#k"  # c\ny = 1\n', 'x = "#k"     \ny = 1\n'),
        (sh_code_only, 'a "#q" $# ${#v} # c\n', 'a "#q" $# ${#v}    \n'),
        (sh_code_only, "f() {  # args\n  it's\n}\n", None),
        (sh_code_only, "cat <<'EOF'\n# kept\ndon't\nEOF\nx # c\n",
         "cat <<'EOF'\n# kept\ndon't\nEOF\nx    \n"),
    ]:
        cases.note()
        got = function(source)
        assert len(got) == len(source), (function.__name__, source, got)
        if want is not None:
            assert got == want, (function.__name__, source, got)
    cases.note()
    assert compact('a ( 1 ) ; // c\n s( " x  y " ) /* d */') == 'a(1);s(" x  y ")'
    report_pass("source-scan-cache controls",
                f"production passes and {cases.ran} uncached, bounded, stale or "
                f"mutable shapes and comment blankings behave as specified", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
