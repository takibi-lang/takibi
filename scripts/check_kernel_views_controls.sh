#!/usr/bin/env bash
# Controls for the shared view comparison (GitHub issue #530).
#
# Both lane runners used to hold this loop, and each was only ever exercised
# by a full boot. Holding it once makes it worth asserting directly: what
# follows costs milliseconds and pins the four behaviours that were paid for
# in debugging rounds rather than designed -- report every mismatch instead
# of stopping at the first, purge stale `.actual` files, refuse a run that
# compared nothing, and let a platform file override a common one.
#
# The normalization is here too, because it is what #530 was filed about: the
# two copies had already drifted, and the drift decided what a shared view was
# allowed to assert.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/kernel_views.sh
source "$repo_root/scripts/kernel_views.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# GitHub issue #526: a control asserts the number of claims it made. A PASS
# that names zero of them is a run that checked nothing, which is the same
# silence scripts/pass_line.py refuses on the Python side.
cases=0
claim() { cases=$((cases + 1)); }

fail() { echo "FAIL kernel-views-control: $*" >&2; exit 1; }

common="$tmp_dir/common"
platform="$tmp_dir/platform"
overlay="$tmp_dir/overlay"
artifacts="$tmp_dir/artifacts"
mkdir -p "$common" "$platform" "$overlay" "$artifacts"

log="$tmp_dir/uart.log"
printf '/ # alpha: one\r\n' >"$log"
printf 'beta: two\r\n' >>"$log"
printf '[000012.345678] gamma: three\r\n' >>"$log"
printf 'persistent shell: child forked pid=417\r\n' >>"$log"

kernel_views_normalize "$log"

# Normalization: the interactive prompt is stripped, the CR is gone, a dmesg
# timestamp becomes `[<time>]`, and a monotonically minted pid becomes
# `<child>`. The timestamp rule is the one the two runners disagreed about;
# the pid line is written CR-terminated on purpose, because its rule is
# `$`-anchored and used to see the CR.
[ "$(sed -n 1p "$log.normalized")" = "alpha: one" ] && claim ||
    fail "the interactive prompt was not stripped"
[ "$(sed -n 3p "$log.normalized")" = "[<time>] gamma: three" ] && claim ||
    fail "the dmesg timestamp prefix was not normalized"
[ "$(sed -n 4p "$log.normalized")" = "persistent shell: child forked pid=<child>" ] && claim ||
    fail "the minted pid was not normalized"
grep -q $'\r' "$log.normalized" && fail "carriage returns survived normalization"

printf '^alpha: \n' >"$common/first.filter"
printf 'alpha: one\n' >"$common/first.expected"
printf '^beta: \n' >"$common/second.filter"
printf 'beta: two\n' >"$common/second.expected"
printf '^\\[<time>\\] gamma: \n' >"$common/third.filter"
printf '[<time>] gamma: three\n' >"$common/third.expected"

# Every view passes.
kernel_views_compare control "$artifacts" "$log.normalized" \
    "$common" "$platform" >/dev/null 2>&1 && claim ||
    fail "a tree whose every view matches was refused"
[ "$kernel_views_passed" -eq 3 ] && claim ||
    fail "counted $kernel_views_passed views, expected 3"
[ -z "$kernel_views_failed" ] && claim || fail "a passing run named failures"

# Two mismatches: BOTH are named. Stopping at the first is what made a run
# report one failing view when seventeen had failed.
printf 'alpha: wrong\n' >"$common/first.expected"
printf 'beta: wrong\n' >"$common/second.expected"
# Captured to a file rather than through `$(...)`: a command substitution
# runs in a subshell, and the verdict this function reports is in variables
# it sets.
report="$tmp_dir/report.txt"
status=0
kernel_views_compare control "$artifacts" "$log.normalized" \
    "$common" "$platform" >"$report" 2>&1 || status=$?
[ "$status" -eq 1 ] && claim || fail "two failing views returned $status, expected 1"
[ "$kernel_views_failed" = " first second" ] && claim ||
    fail "named '$kernel_views_failed', expected both failing views"
grep -q "^PASS control view: third$" "$report" && claim ||
    fail "the view after the failures was never compared" 

# The stale `.actual` purge. A view that fails leaves its own .actual behind
# for reading; a view that is no longer compared must not leave LAST run's
# output looking like this run's, which cost a re-diagnosis of a fixed leak.
printf 'stale\n' >"$artifacts/removed_view.actual"
printf 'alpha: one\n' >"$common/first.expected"
printf 'beta: two\n' >"$common/second.expected"
kernel_views_compare control "$artifacts" "$log.normalized" \
    "$common" "$platform" >/dev/null 2>&1 && claim ||
    fail "the repaired tree was refused"
[ ! -f "$artifacts/removed_view.actual" ] && claim ||
    fail "a stale .actual from a previous run survived"

# A platform filter overrides a common one of the same name, and an
# expected-override overlays the expected content for another build.
printf '^beta: \n' >"$platform/second.filter"
printf 'beta: two\n' >"$platform/second.expected"
printf 'beta: two\n' >"$overlay/second.expected"
kernel_views_compare control "$artifacts" "$log.normalized" \
    "$common" "$platform" "$overlay" >/dev/null 2>&1 && claim ||
    fail "platform and overlay lookup refused a matching tree"
[ "$kernel_views_passed" -eq 3 ] && claim ||
    fail "override changed the view count to $kernel_views_passed"
printf 'beta: overridden\n' >"$overlay/second.expected"
status=0
kernel_views_compare control "$artifacts" "$log.normalized" \
    "$common" "$platform" "$overlay" >/dev/null 2>&1 || status=$?
[ "$status" -eq 1 ] && claim ||
    fail "the expected-override was not consulted ahead of the platform file"

# No view compared is not a pass. The loop finds its filters by glob, and a
# glob that stops matching would otherwise report success having read no
# contract at all.
status=0
kernel_views_compare control "$artifacts" "$log.normalized" \
    "$tmp_dir/empty-common" "$tmp_dir/empty-platform" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] && claim || fail "an empty view set returned $status, expected 2"

# A filter with no expected file beside it is a configuration error, not an
# empty comparison.
printf '^alpha: \n' >"$platform/orphan.filter"
status=0
kernel_views_compare control "$artifacts" "$log.normalized" \
    "$common" "$platform" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] && claim || fail "a filter with no expected file returned $status, expected 2"

echo "PASS kernel-views controls: $cases claims -- normalization strips the prompt, the CR, the dmesg timestamp and the minted pid; every mismatch is named rather than the first; a stale .actual is purged; platform and overlay lookup win in that order; and comparing nothing fails"
