#!/usr/bin/env python3
"""Function extraction preserves bodies without rescanning the kernel per name.

Count source characters handed to regex scans, not elapsed time. This gives
the fast lane a deterministic regression for the CI timeout without creating
another timing game on the same overloaded runner.
"""

import re

import check_model_function_map as mapping
from pass_line import CaseCount, report_pass


class ScanCounter:
    def __init__(self, source_size):
        self.source_size = source_size
        self.work = 0

    def __getattr__(self, name):
        delegate = getattr(re, name)
        if name not in ("search", "finditer", "sub"):
            return delegate

        def counted(*args, **kwargs):
            text = args[2] if name == "sub" else args[1]
            if len(text) == self.source_size:
                self.work += len(text)
            return delegate(*args, **kwargs)

        return counted


def main():
    cases = CaseCount()
    bodies = {}
    for index in range(64):
        qualifier = ("", "private ", "inline ", "private noinline ")[index % 4]
        name = f"indexed_{index}"
        bodies[name] = (f"{qualifier}fn {name}() -> usize !{{io}} {{\n"
                        'let text = "} // not a comment"; /* } */\n'
                        f"if (true) {{ return {index}; }}\n}}")
    source = "\n".join(bodies.values()) + "\nfn indexed_0() { return 999; }\n"
    for name in ("masked_sources", "function_starts", "function_body"):
        function = getattr(mapping, name, None)
        if hasattr(function, "cache_clear"):
            function.cache_clear()
    counter = ScanCounter(len(source))
    original = mapping.re
    mapping.re = counter
    try:
        for _ in range(2):
            for name, expected in bodies.items():
                cases.note()
                assert mapping.function_body(name, source) == expected, name
            cases.note()
            assert mapping.function_body("absent", source) is None
    finally:
        mapping.re = original
    if counter.work > 2 * len(source):
        raise SystemExit("FAIL model-function-map controls: function extraction "
                         "rescanned the full source per lookup")
    report_pass("model-function-map controls",
                "qualified/effectful bodies, nested blocks and the first duplicate definition survive; full-source scan work stays constant across lookups",
                cases=cases.ran)


if __name__ == "__main__":
    main()
