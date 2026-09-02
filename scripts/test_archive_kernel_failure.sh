#!/usr/bin/env bash
# Regression controls for the failing-lane archive.
#
# The shape it exists to stop: an intermittent failure's evidence being
# overwritten by the next run before anyone reads it, which cost two
# diagnoses on 2026-08-30. So the controls are that it keeps EVERYTHING on a
# failure and that a second failure in the same second does not merge two
# captures into one directory.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archiver="$repo_root/scripts/archive_kernel_failure.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() { echo "FAIL archive-control: $*" >&2; exit 1; }

src="$tmp_dir/artifacts"
mkdir -p "$src/nested"
printf 'uart bytes\n' >"$src/uart.log"
printf 'view\n' >"$src/boot.actual"
printf 'deep\n' >"$src/nested/extra.log"

root="$tmp_dir/failures"
bash "$archiver" "$src" "$root" "control reason" >/dev/null 2>&1 ||
    fail "archiver exited non-zero"
one="$(find "$root" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$one" ] || fail "no archive directory was created"
[ -f "$one/uart.log" ] || fail "uart.log was not kept"
[ -f "$one/nested/extra.log" ] || fail "nested files were not kept"
grep -q "reason: control reason" "$one/MANIFEST" || fail "MANIFEST lost the reason"
grep -q "^commit: " "$one/MANIFEST" || fail "MANIFEST lost the commit"

# A second archive in the same second must not merge into the first.
bash "$archiver" "$src" "$root" "second" >/dev/null 2>&1 || fail "second archive failed"
count="$(find "$root" -mindepth 1 -maxdepth 1 -type d | wc -l)"
[ "$count" -eq 2 ] || fail "two archives collapsed into $count directory(ies)"

# A missing artifact directory is not an error: the lane may have died before
# writing anything, and the archiver must not turn that into a second failure.
bash "$archiver" "$tmp_dir/absent" "$root" "none" >/dev/null 2>&1 ||
    fail "archiver failed on a missing artifact directory"

echo "PASS archive-control: a failing lane's whole capture survives, and two failures do not merge"
