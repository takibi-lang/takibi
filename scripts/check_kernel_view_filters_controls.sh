#!/usr/bin/env bash
# Controls for scripts/check_kernel_view_filters.sh (GitHub issue #834), in
# both directions, on throwaway view trees.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$repo_root/scripts/check_kernel_view_filters.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cases=0
fail() { echo "FAIL kernel-view-filters-control: $*" >&2; exit 1; }

# fresh: a tree where every expected line is selected.
fresh() {
    local t="$tmp_dir/$1"
    mkdir -p "$t/common/views" "$t/qemu/views" "$t/rpi5/views" "$t/qemu-debug/views"
    printf '^alpha: \n^beta\n' >"$t/common/views/a.filter"
    printf 'alpha: one\nbeta two\n' >"$t/common/views/a.expected"
    echo "$t"
}

# expect_pass <tree> / expect_fail <tree> <needle>
expect_pass() {
    bash "$check" "$1" >/dev/null 2>"$tmp_dir/err" ||
        fail "$1 refused: $(cat "$tmp_dir/err")"
    cases=$((cases + 1))
}
expect_fail() {
    if bash "$check" "$1" >/dev/null 2>"$tmp_dir/err"; then
        fail "$1 accepted"
    fi
    grep -qF -- "$2" "$tmp_dir/err" || fail "$1 did not name '$2': $(cat "$tmp_dir/err")"
    cases=$((cases + 1))
}

# Positive: the clean tree.
expect_pass "$(fresh clean)"

# Negative: the #826 shape -- a new expected line its filter does not select.
t="$(fresh missing)"
printf 'settings_wake: ok\n' >>"$t/common/views/a.expected"
expect_fail "$t" "    settings_wake: ok"

# Negative: a platform expected file is held to the resolved filter.
t="$(fresh platform-expected)"
printf 'alpha: one\ngamma\n' >"$t/rpi5/views/a.expected"
expect_fail "$t" "rpi5: lines of rpi5/views/a.expected"

# Positive: a platform filter overrides the common one for its lane, so a
# line only the platform filter selects passes there.
t="$(fresh platform-filter)"
printf '^alpha: \n^gamma\n' >"$t/qemu/views/a.filter"
printf 'alpha: one\ngamma\n' >"$t/qemu/views/a.expected"
expect_pass "$t"

# Negative: the qemu-debug overlay is held to the QEMU lane's filter.
t="$(fresh overlay)"
printf 'alpha: one\ndelta\n' >"$t/qemu-debug/views/a.expected"
expect_fail "$t" "lines of qemu-debug/views/a.expected"

# Negative: an expected file no lane compares.
t="$(fresh orphan)"
printf 'x\n' >"$t/common/views/orphan.expected"
expect_fail "$t" "common/views/orphan.expected is compared by no lane"

# Negative: a tree with no views is not a pass.
mkdir -p "$tmp_dir/empty/common/views"
expect_fail "$tmp_dir/empty" "no view pairs found"

[ "$cases" -eq 7 ] || fail "expected 7 claims, made $cases"
echo "PASS kernel-view-filters-control: $cases cases"
