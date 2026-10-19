#!/usr/bin/env bash
# Every line of a kernel view's .expected file is selected by its .filter.
#
# GitHub issue #834. A view is `grep -E -f <filter>` over one boot's capture,
# compared with `<expected>`. An expected line the filter does not select can
# never appear in the selection, so the view fails on every boot -- but only
# on a booted lane, minutes (QEMU) or a board lease (RPi5) later. #826 added
# a `settings_wake` line to an .expected file and not to its .filter and paid
# exactly that round trip.
#
# The selection is kernel_views_select from scripts/kernel_views.sh, the very
# function the lanes run, applied to the .expected file itself; so is the
# platform-over-common resolution of which filter and which expected file a
# lane compares. The `qemu-debug` overlay (KERNEL_QEMU_EXPECTED_VIEW_DIR) is
# held to the QEMU lane's filters. An .expected file no lane would read is
# refused too: it is a contract nothing checks.
#
# Usage: check_kernel_view_filters.sh [tests-root]  (default kernel/tests)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/kernel_views.sh
source "$repo_root/scripts/kernel_views.sh"

root="${1:-$repo_root/kernel/tests}"
common="$root/common/views"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

failures=0
pairs=0
declare -A used=()

# check_pair <label> <filter> <expected>
check_pair() {
    local label="$1" filter="$2" expected="$3"
    pairs=$((pairs + 1))
    used["$expected"]=1
    kernel_views_select "$filter" "$expected" >"$tmp"
    # Builtin reads, not cmp: this runs once per pair inside the fast gate's
    # CPU budget, and a fork per pair is most of what the check costs.
    local want got
    IFS= read -r -d '' want <"$expected" || true
    IFS= read -r -d '' got <"$tmp" || true
    if [ "$want" != "$got" ]; then
        echo "FAIL kernel-view-filters: $label: lines of ${expected#"$root"/} not selected by ${filter#"$root"/}:" >&2
        # The selection is a subsequence of the file, so the removed lines
        # are exactly the ones the filter misses.
        diff "$expected" "$tmp" | sed -n 's/^< /    /p' >&2 || true
        failures=$((failures + 1))
    fi
}

# check_lane <lane> [expected-overlay-dir]
check_lane() {
    local lane="$1" overlay="${2:-}" platform="$root/$1/views"
    local name filter expected
    for name in $(
        for f in "$common"/*.filter "$platform"/*.filter; do
            [ -e "$f" ] || continue
            f="${f##*/}"
            echo "${f%.filter}"
        done | LC_ALL=C sort -u
    ); do
        if [ -f "$platform/$name.filter" ]; then
            filter="$platform/$name.filter"
        else
            filter="$common/$name.filter"
        fi
        if [ -n "$overlay" ]; then
            [ -f "$overlay/$name.expected" ] || continue
            expected="$overlay/$name.expected"
        elif [ -f "$platform/$name.expected" ]; then
            expected="$platform/$name.expected"
        elif [ -f "$common/$name.expected" ]; then
            expected="$common/$name.expected"
        else
            continue  # the lane reports the missing file itself
        fi
        check_pair "$lane" "$filter" "$expected"
    done
}

check_lane qemu
check_lane rpi5
check_lane qemu "$root/qemu-debug/views"

for expected in "$root"/*/views/*.expected; do
    [ -e "$expected" ] || continue
    if [ -z "${used[$expected]:-}" ]; then
        echo "FAIL kernel-view-filters: ${expected#"$root"/} is compared by no lane (no matching .filter)" >&2
        failures=$((failures + 1))
    fi
done

if [ "$failures" -ne 0 ]; then
    exit 1
fi
if [ "$pairs" -eq 0 ]; then
    echo "FAIL kernel-view-filters: no view pairs found under $root" >&2
    exit 1
fi
echo "PASS kernel-view-filters: $pairs filter/expected pairs; every expected line is selected"
