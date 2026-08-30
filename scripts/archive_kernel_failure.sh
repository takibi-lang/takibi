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
} >"$archive/MANIFEST"

echo "archived full capture to: $archive" >&2
