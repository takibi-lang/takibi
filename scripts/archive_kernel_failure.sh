#!/usr/bin/env bash
# Snapshot a failing kernel lane's whole capture somewhere nothing overwrites.
#
# GitHub issue #233 taught the RPi5 runner to do this for a failing VIEW: an
# intermittent failure's own artifact directory is silently replaced the next
# time anyone runs the lane, and #233's first two reproductions each lost
# their raw UART transcript before it could be read.
#
# Extended 2026-08-30 for two gaps that cost real diagnoses the same day:
#
#   - The QEMU lane had no archiving at all. A `records MISSING` failure
#     (issue #488) was reproduced, and its uart.log was gone by the time the
#     next run finished -- twice.
#   - The RPi5 lane archived only on a view mismatch, so the ARP, TCP and
#     reset failures that fail EARLIER (issue #387) left nothing behind. The
#     ARP diagnosis had to wait until a failure happened to land on the last
#     run of a batch.
#
# So this is called from an EXIT trap on a nonzero status, not from the
# view-comparison block: whatever the lane died of, the evidence survives.
#
# One script rather than a copy in each runner, for the reason
# scripts/check_platform_file_parity.py exists: two copies of the same block
# in two files that are never run together are free to drift.
#
# Usage: archive_kernel_failure.sh <artifact_dir> <archive_root> <reason...>
set -euo pipefail

artifact_dir="$1"
archive_root="$2"
shift 2
reason="$*"

[ -d "$artifact_dir" ] || exit 0

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$archive_root/$stamp"
# A second failure inside the same second would otherwise merge two captures
# into one directory and make both unreadable. Rare, and cheap to exclude.
suffix=0
while [ -e "$archive" ]; do
    suffix=$((suffix + 1))
    archive="$archive_root/$stamp-$suffix"
done
mkdir -p "$archive"

# Everything the lane wrote, not a chosen subset: which file turns out to
# matter is exactly what is unknown while an intermittent failure is still
# undiagnosed.
cp -pr "$artifact_dir"/. "$archive/" 2>/dev/null || true

{
    echo "reason: $reason"
    date -u +%Y-%m-%dT%H:%M:%SZ
    echo "commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "dirty: $(git status --porcelain 2>/dev/null | wc -l) file(s)"
    # Which kernel and lane produced this capture. A race-window lane runs an
    # armed and a reverted kernel back to back on the same ports, and a
    # reverted run is meant to fail: without these two lines its archive looks
    # like an armed failure (GitHub issue #665).
    # The host's load, because a lane that hit its guest timeout on a busy
    # machine and a guest that stopped look alike in the capture (#665).
    echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"
    # GitHub issues #854 and #876: a load figure says the host was busy, not
    # WHAT was busy. On 2026-10-21 four lanes went silent at once inside the
    # lock-step boot probes (pid, freelist, pool walk) with load 70.9 on 24
    # host CPUs and only 24 leased vCPUs, so most of that load was work the
    # vCPU lease does not count -- and nothing recorded whose. So: the host's
    # runnable/total task count, its CPU split (the load average and this line
    # are host-wide; `top` lists only this container's processes, so a hog in
    # another container shows as busy CPU with no process here), and the
    # busiest processes this container can see, from top's second sample so
    # %CPU is current rather than lifetime.
    echo "running: $(cut -d' ' -f4 /proc/loadavg 2>/dev/null || echo unknown)"
    if command -v top >/dev/null 2>&1; then
        top -b -n 2 -d 0.5 -o %CPU -w 200 2>/dev/null |
            awk '/^top -/ { frame++ } frame == 2' |
            awk '/^%Cpu/ { print "host cpu: " $0; next }
                 /^ *PID / { table = 1; next }
                 table && shown < 15 && NF >= 12 && $9 + 0 > 0 {
                     print "top: " $1 " " $9 "% " $12; shown++ }' || true
    fi
    echo "lane: ${KERNEL_QEMU_LABEL:-unknown}"
    echo "kernel: $(basename "${KERNEL_QEMU_ELF:-unknown}")"
    # GitHub issue #883: which lane run made this archive, and, for one a
    # passing lane makes on purpose, why. scripts/run_lane.sh refuses a
    # passing lane that left an archive without an expected: reason.
    echo "lane-run: ${TAKIBI_LANE_RUN_ID:-none}"
    echo "expected: ${TAKIBI_ARCHIVE_EXPECTED:-no}"
    if [ -f "$archive/console-state.log" ]; then
        echo "console snapshot: console-state.log"
        cat "$archive/console-state.log"
    fi
} >"$archive/MANIFEST"

echo "archived full capture to: $archive" >&2
