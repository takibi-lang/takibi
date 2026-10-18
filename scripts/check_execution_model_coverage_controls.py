#!/usr/bin/env python3
"""Controls for check_execution_model_coverage.py's assert rule (GitHub
issue #814): a comment-only mention of an execution-model constant is
refused, a real static_assert is accepted, an EXEMPT entry with a reason is
accepted, and an EXEMPT entry with an empty reason is refused.
"""

import sys

sys.dont_write_bytecode = True
import check_execution_model_coverage as check  # noqa: E402
from pass_line import report_pass  # noqa: E402

STATE = "let mut word: usize = 0;\n"
COMMENT_ONLY = STATE + "// This does not depend on KERNEL_PREEMPTIBLE.\n"
TRAILING = STATE + "fn f() { g(); } // static_assert(KERNEL_ACTIVE_CORES == 1, \"x\");\n"
ASSERTED = STATE + (
    "fn f() {\n"
    "    static_assert(KERNEL_PREEMPTIBLE == 0,\n"
    "                  \"word is safe only without preemption\");\n"
    "}\n")
ASSERT_URL_MSG = STATE + (
    "fn f() { static_assert(KERNEL_ACTIVE_CORES == 1, \"see https://x\"); }\n")
OTHER_ASSERT = STATE + (
    "fn f() { static_assert(KERNEL_MAX_CORES == 4, \"KERNEL_ACTIVE_CORES\"); }\n")


def main() -> int:
    cases = [
        ("a.tkb", COMMENT_ONLY, {}, "silent", "comment-only mention accepted"),
        ("a.tkb", TRAILING, {}, "silent", "assert inside a trailing comment accepted"),
        ("a.tkb", OTHER_ASSERT, {}, "silent",
         "constant named only in an assert message accepted"),
        ("a.tkb", ASSERTED, {}, "assert", "real static_assert refused"),
        ("a.tkb", ASSERT_URL_MSG, {}, "assert", "assert with // in its message refused"),
        ("a.tkb", COMMENT_ONLY, {"a.tkb": "boot-only state, CPU0"}, "exempt",
         "EXEMPT with a reason refused"),
        ("a.tkb", COMMENT_ONLY, {"a.tkb": "  "}, "no-reason",
         "EXEMPT with an empty reason accepted"),
    ]
    for rel, text, exempt, want, message in cases:
        got = check.verdict(rel, text, exempt)
        assert got == want, "%s (got %s)" % (message, got)
    report_pass("execution-model-coverage controls",
                "%d planted cases classified as expected" % len(cases),
                cases=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
