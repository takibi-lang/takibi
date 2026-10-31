#!/usr/bin/env python3
"""Controls for source_scan.function_header and its spelling check (#1296):
every header the grammar allows is recognised, `extern fn` and a call are not,
and each hand-written spelling that once hid a function is refused."""

import sys

import check_function_header_parser as check
from pass_line import report_pass
from source_scan import function_header, header_is_private

failures = []


def expect(label, condition):
    if not condition:
        failures.append(label)


def main():
    cases = 0
    for head, private in (("fn", False), ("inline fn", False), ("noinline fn", False),
                          ("private fn", True), ("private inline fn", True),
                          ("private noinline fn", True), ("    inline  fn", False),
                          ("private\ninline\nfn", True)):
        cases += 1
        found = function_header().search(f"x\n{head} name(a: usize) {{ }}\n")
        expect(f"{head!r} is a header", found and found[1] == "name")
        expect(f"{head!r} privacy", found and header_is_private(found) == private)
        public = function_header(public_only=True).search(f"{head} name() {{ }}\n")
        if "\n" not in head:  # public_only reads privacy on the header's own line
            expect(f"{head!r} public_only", (public is None) == private)
    for text in ("extern fn name();\n", "let f = fn_name(1);\n", "x.fn name\n",
                 "refn name()\n"):
        cases += 1
        expect(f"{text!r} is no header", function_header().search(text) is None)
    narrowed = function_header(r"\w+_run", r"\((\w+)").search("fn a_run(b) {}\nfn other(c) {}\n")
    expect("name and suffix groups", narrowed and narrowed[1] == "a_run" and narrowed[2] == "b")

    for line in (
            r'''re.compile(r"^\s*(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)", re.M)''',
            r'''re.compile(r"^(?:private )?(?:inline |noinline )?fn (\w+)\(")''',
            r'''re.compile(r"^(private\s+)?fn\s+(\w+)")''',
            r'''re.compile(r"^fn (\w+)\(", re.M)''',
            r'''re.compile(r"^\s*fn\s+(\w+)")'''):
        cases += 1
        expect(f"refused: {line}", check.spellings(line) == (1,))
    for line in (r'''re.search(r"fn kill_signal_accepted\(signum", text)''',
                 r'''source = "inline fn planted() { }"''',
                 r'''FUNCTION = function_header(suffix=r"\(")'''):
        cases += 1
        expect(f"accepted: {line}", check.spellings(line) == ())
    if failures:
        for failure in failures:
            print(f"FAIL function-header-parser controls: {failure}", file=sys.stderr)
        return 1
    report_pass("function-header-parser controls",
                "the grammar's headers recognised; hand-written spellings refused",
                cases=cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())
