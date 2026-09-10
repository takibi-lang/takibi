#!/usr/bin/env bash
# One boot, several independent views -- the comparison itself, held once.
#
# GitHub issue #530. Both lane runners carried this loop, 27 significant
# lines each, and the copies had already drifted: QEMU's normalization
# rewrote the dmesg timestamp prefix and the board's did not, which is not a
# cosmetic difference. It decided what a SHARED view was allowed to assert,
# so `kernel/tests/qemu/views/dmesg` was a QEMU-only view because of how its
# runner happened to preprocess text rather than because the retained-log
# replay is platform-specific -- and the board never asserted that replay at
# all.
#
# scripts/check_platform_file_parity.py cannot see this: these are shell, not
# a same-named pair of platform .tkb files. What keeps the copies together
# now is that there is one.
#
# Sourced, not executed. The RPi5 runner reports its views and then goes on
# to drive DDB on the still-running kernel, so it needs the verdict as a
# value rather than as an exit; the QEMU runner fails immediately on the same
# value. Callers read `kernel_views_passed` and `kernel_views_failed`.

# Project a raw UART capture onto the text views compare.
#
# The real UART echoes a shell command immediately after the prompt, so a
# command's short output can arrive as `/ # repl-ok` rather than as a separate
# line. Views describe semantic output, not the interactive prompt.
#
# The dmesg replay prints each retained record with its own timestamp, and a
# timestamp is a measurement rather than a contract -- but the record's
# PRESENCE is one, and `[<time>]` is how a view asserts the second without
# the first. scripts/validate_kernel_dmesg_timestamps.py is what judges the
# numbers, on both lanes.
#
# The persistent-shell checkpoints name the tracked child's pid, and a pid is
# minted monotonically rather than read off the process slot (issue #392), so
# its VALUE counts how many processes the boot created before this fixture --
# an artifact of fixture order, not of what this view means. That the four
# checkpoints all name the SAME child is enforced in the kernel, which logs
# each of the last three only on a match against the pid the fork checkpoint
# recorded.
# The CR is deleted FIRST. Both copies of this used to run sed over the raw
# capture and strip carriage returns afterwards, so `$`-anchored rules only
# fired on lines the capture happened not to CR-terminate -- true of the
# checkpoint lines today, and nothing said so or would have noticed it
# changing. Deleting the CR first makes the rules mean what they read as.
kernel_views_normalize() {
    local uart_log="$1"
    tr -d '\r' <"$uart_log" | sed -e 's|^/ # ||' \
        -e 's|^\[[0-9][0-9]*\.[0-9][0-9]*\] |[<time>] |' \
        -e 's|^\(persistent shell: [a-z ]*\)pid=[0-9][0-9]*$|\1pid=<child>|' \
        >"$uart_log.normalized"
}

# Compare every view of one boot.
#
# Common views are supplemented by platform-specific views; a platform file
# overrides a common file with the same name. An expected-override directory
# overlays expected output for another BUILD of the same platform, such as
# the larger DWARF-bearing debug ELF; pass an empty string when there is
# none. Adding a subsystem test does not require another reset/load cycle.
#
# Returns 0 when every view passed, 1 when any mismatched, and 2 for a
# configuration error it has already reported.
kernel_views_compare() {
    local label="$1" artifact_dir="$2" normalized="$3"
    local common_dir="$4" platform_dir="$5" expected_override="${6:-}"

    # The loop used to stop at the first mismatch, so every .actual after it
    # kept the LAST run's content -- which reads exactly like this run's
    # output and is not. That cost a debugging round trip: a fixed leak was
    # re-diagnosed from a stale file. Purge them so a missing .actual means
    # "never compared", which is the truth.
    rm -f "$artifact_dir"/*.actual
    kernel_views_passed=0
    kernel_views_failed=""

    local view_names
    view_names="$(
        for filter in "$common_dir"/*.filter "$platform_dir"/*.filter; do
            [ -e "$filter" ] || continue
            basename "$filter" .filter
        done | LC_ALL=C sort -u
    )"

    local name filter expected actual
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -f "$platform_dir/$name.filter" ]; then
            filter="$platform_dir/$name.filter"
        else
            filter="$common_dir/$name.filter"
        fi
        if [ -n "$expected_override" ] &&
                [ -f "$expected_override/$name.expected" ]; then
            expected="$expected_override/$name.expected"
        elif [ -f "$platform_dir/$name.expected" ]; then
            expected="$platform_dir/$name.expected"
        else
            expected="$common_dir/$name.expected"
        fi
        actual="$artifact_dir/$name.actual"
        if [ ! -f "$expected" ]; then
            echo "error: missing expected file for kernel view $name" >&2
            return 2
        fi
        LC_ALL=C grep -E -f "$filter" "$normalized" >"$actual" || true
        if ! cmp -s "$expected" "$actual"; then
            # Report and keep going. Stopping at the first mismatch made the
            # output say "one view failed" when seventeen had, because every
            # view after it was never compared -- which is also why the
            # .actual purge above exists. Comparing all of them costs one
            # grep each against an already-captured log, and a change that
            # moves several views at once is exactly when the whole list is
            # what you need.
            echo "FAIL $label view: $name" >&2
            diff -u "$expected" "$actual" >&2 || true
            kernel_views_failed="$kernel_views_failed $name"
            continue
        fi
        echo "PASS $label view: $name"
        kernel_views_passed=$((kernel_views_passed + 1))
    done <<<"$view_names"

    if [ -n "$kernel_views_failed" ]; then
        return 1
    fi
    if [ "$kernel_views_passed" -eq 0 ]; then
        # No view compared is not a pass. This is the whole "PASS about
        # nothing" shape: the loop above finds its filters by glob, and a
        # glob that stops matching reports success having read no contract
        # at all.
        echo "error: no kernel integration views found under $common_dir or $platform_dir" >&2
        return 2
    fi
    return 0
}
