#!/usr/bin/env python3
# Static, build-time guard for a documentation convention established
# 2026-08-07 (issues #207/#242, see HISTORY.md's entry for that date):
# every kernel/lib/ file must carry a "Current limitations" section near
# its top, stating what today's callers happen to guarantee (e.g. single-
# execution-context access) that the file itself does not enforce or
# check.
#
# Why this is worth a build-time check rather than just a review habit:
# the user directly raised a past incident where a library not designed
# for thread-safety was adopted widely and then implicitly required to
# be thread-safe, and broke -- the fix agreed on was to make the current,
# actual scope of what a shared data-structure library guarantees
# impossible to miss, not to guess at solving the harder problem (a
# genuinely concurrent caller) preemptively. A convention that lives only
# in a memory/habit quietly stops being followed the moment someone is
# in a hurry; this makes forgetting it a build failure instead.
#
# This check is deliberately shallow -- it only confirms the marker
# phrase is PRESENT somewhere in the file's leading comment block, not
# that the content is accurate or current. Staying accurate is still a
# human judgment call (see kernel/lib/freelist.tkb's own header: "Keep
# this list current as call sites change; a limitation that goes stale
# here is worse than none").
#
# Exit code only (0 = pass, 1 = fail); intended to run as part of
# `make kernelbuild-rpi5`, independent of and before the actual compile
# (pure source-text check, no build product needed).

import sys
from pathlib import Path

MARKER = "Current limitations"
# How far into the file (in leading comment lines) the marker must
# appear -- generous enough for a real design-rationale header
# (kernel/lib/freelist.tkb's own header runs ~90 lines) without allowing
# a marker buried arbitrarily deep to count as "near the top."
LEADING_LINES = 150


def files_missing_header(lib_dir):
    missing = []
    for path in sorted(lib_dir.glob("*.tkb")):
        lines = path.read_text().splitlines()[:LEADING_LINES]
        if not any(MARKER in line for line in lines):
            missing.append(path)
    return missing


def main():
    if len(sys.argv) != 2:
        print("usage: check_kernel_lib_limitations_header.py <kernel/lib dir>",
              file=sys.stderr)
        return 1
    lib_dir = Path(sys.argv[1])
    if not lib_dir.is_dir():
        print("error: %s is not a directory" % lib_dir, file=sys.stderr)
        return 1
    missing = files_missing_header(lib_dir)
    if missing:
        for path in missing:
            print(
                "FAIL kernel-lib/limitations-header: %s has no '%s' "
                "section in its first %d lines -- every kernel/lib/ file "
                "must document what today's callers happen to guarantee "
                "(e.g. single-execution-context access) that the file "
                "itself does not enforce (see HISTORY.md's 2026-08-07 "
                "issue #207/#242 entry, and kernel/lib/freelist.tkb's own "
                "header for the expected shape)."
                % (path, MARKER, LEADING_LINES),
                file=sys.stderr,
            )
        return 1
    print(
        "PASS kernel-lib/limitations-header: every kernel/lib/*.tkb file "
        "documents its current limitations"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
