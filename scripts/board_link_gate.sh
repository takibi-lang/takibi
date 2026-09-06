#!/usr/bin/env bash
# One answer to "is the board's link up yet", for every hardware net runner.
#
# GitHub issue #387: one readiness gate before the first wire test, rather
# than one answer per test script. The runners used to start a board and run
# a test with nothing in between. The raw AF_PACKET tests survived that by
# resending every frame, so the gap only showed up in the tests that go
# through the host kernel's own stack and get a single attempt -- and a board
# that was simply not up yet was reported as a protocol defect in whatever
# ran first. Of three network flakes in this tree, one was the stack and two
# were the harness assuming a readiness it had not established.
#
# The target already says when it is ready; nothing has to be added to it.
# The maintained kernel prints `rp1 gem: link ready` / `rp1 gem: link failed`,
# and every STM32 net example prints `<example>: ready` /
# `<example>: device/link not found` once net_init() has returned -- and
# net_init() waits for auto-negotiation-complete AND link-up, so the ready
# line means the link exists rather than that the firmware started.
#
# A failed bring-up is a different answer from a slow one, and both targets
# distinguish them, so this does too rather than spending the whole window
# discovering it.
#
# Sourced, not executed: the caller keeps its own FAIL wording and decides
# whether to stop the run or record one failed test. This prints the reason
# and nothing else.

# board_link_gate LOG READY_MARKER FAILED_MARKER TICKS
#
# Polls LOG at 0.1s intervals for TICKS ticks. Returns 0 as soon as
# READY_MARKER appears, 1 as soon as FAILED_MARKER does, and 1 on expiry.
# The markers are fixed strings, not patterns.
#
# The elapsed time is printed on success because it is GitHub issue #411's
# number and this measures it directly: a retry budget against a boot nobody
# had timed is exactly the pairing that issue was opened about.
board_link_gate() {
    local log="$1" ready="$2" failed="$3" ticks="$4" tick

    for tick in $(seq 1 "$ticks"); do
        if grep -aFq "$ready" "$log" 2>/dev/null; then
            printf 'link ready %ss after start\n' \
                "$(awk -v t="$tick" 'BEGIN { printf "%.1f", t * 0.1 }')"
            return 0
        fi
        if grep -aFq "$failed" "$log" 2>/dev/null; then
            printf 'the target reported "%s"\n' "$failed"
            return 1
        fi
        sleep 0.1
    done
    printf 'the target never printed "%s" in %ss -- it did not reach a usable link, which is NOT a defect in the tests that follow\n' \
        "$ready" "$(awk -v t="$ticks" 'BEGIN { printf "%.0f", t * 0.1 }')"
    return 1
}
