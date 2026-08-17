#!/usr/bin/env bash
# Lists every failing test/test_takibi.ml case in one place, with its
# actual assertion/exception content.
#
# `dune test` (Alcotest under the hood) prints one boxed [FAIL] summary
# per invocation and then a single "N failures!" count -- it does NOT
# print all N failing tests' details in one run the way most test
# runners do. When more than one test fails, everything past the first
# is invisible in the terminal output; the only way to recover the rest
# is to grep Alcotest's own per-test log files under
# `_build/default/test/_build/_tests/takibi/*.output` for a line starting
# with FAIL or containing an uncaught exception marker (NOT simply "is
# this file non-empty": a passing test that uses `Alcotest.(check ...)`
# still logs an "ASSERT <description>" trace line into its own .output
# file on the SUCCESS path -- that tripped up an early version of this
# script, which flagged hundreds of genuinely-passing tests as failures
# by treating "non-empty" as the marker). This script does exactly that,
# instead of it being re-derived by hand each time a change causes
# several failures at once (as happened during the GitHub issue #325
# session that motivated this script -- 33 reported failures, only one
# ever visible in the terminal, the rest found this way).
#
# Usage: scripts/list_dune_test_failures.sh
# Runs `dune test --force` (force, so stale .output files from a
# previous run are never mistaken for current ones), then prints every
# failing test's id and message. Exits 0 if all tests passed, 1 if any
# failed (so it's safe to use as a plain pass/fail check too, not just
# for the listing).

set -euo pipefail
cd "$(dirname "$0")/.."

echo "Running dune test --force..."
if dune test --force > /tmp/list_dune_test_failures.$$.log 2>&1; then
    cat /tmp/list_dune_test_failures.$$.log
    rm -f /tmp/list_dune_test_failures.$$.log
    echo "All tests passed."
    exit 0
fi
cat /tmp/list_dune_test_failures.$$.log
rm -f /tmp/list_dune_test_failures.$$.log

TESTS_DIR="_build/default/test/_build/_tests/takibi"
if [ ! -d "$TESTS_DIR" ]; then
    echo "error: $TESTS_DIR not found (dune's test-output layout may have changed)" >&2
    exit 2
fi

echo
echo "=== Failing tests (from $TESTS_DIR/*.output) ==="
count=0
# `find -L`, not plain `find`: $TESTS_DIR ("takibi") is itself a symlink
# to a per-run directory (dune names it something like "CG9XGMIN" and
# repoints "takibi"/"latest" at it each run) -- plain find's default
# -P (never follow symlinks) does not expand a symlinked STARTING path's
# own contents in this environment, silently matching zero files instead
# of erroring, which is what actually happened testing this script.
#
# Sort by category then numeric id (parser.007 before parser.059) so the
# listing reads in the same order `dune test`'s own [OK]/[FAIL] table
# does, not plain lexical order (which would put parser.100 before
# parser.99).
for f in $(find -L "$TESTS_DIR" -maxdepth 1 -name '*.output' \
    | sed 's/\.output$//' \
    | awk -F. '{print $1"."$2" "$0}' \
    | sort -k1,1 -k2 \
    | awk '{print $2}'); do
    stripped="$(sed 's/\x1b\[[0-9;]*m//g' "$f.output")"
    if printf '%s\n' "$stripped" | grep -qE '^FAIL |\[exception\]'; then
        count=$((count + 1))
        name="$(basename "$f")"
        echo
        echo "--- $name ---"
        printf '%s\n' "$stripped"
    fi
done

echo
echo "$count failing test(s) listed above."
exit 1
