#!/usr/bin/env bash
# The fixture ext2 images are byte-reproducible (GitHub issue #890).
#
# main.o embeds ext2.img, so an image that changes on every rebuild makes
# every kernel object comparison (space_delta, "did this change move any
# byte?") report a difference that is only the mkfs and e2cp clocks. This
# rebuilds both images from the same inputs and fails on any byte
# difference. Its control rebuilds with a different KERNEL_EXT2_FAKE_TIME
# and requires a difference, so a comparison that never sees the image's
# time fields cannot pass.
#
# The images present before the check are restored with their timestamps,
# so the check does not make main.o look stale. Run it from the rule that
# holds the kernel build lock (it rebuilds through $MAKE).
#
# Usage: buildcheck_ext2_reproducible.sh USER_BUILD_DIR FAKE_TIME
set -euo pipefail

trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

dir=${1:?usage: buildcheck_ext2_reproducible.sh USER_BUILD_DIR FAKE_TIME}
epoch=${2:?usage: buildcheck_ext2_reproducible.sh USER_BUILD_DIR FAKE_TIME}
make_cmd=${MAKE:-make}
images=(ext2.img ext2-shell.img)
saved=$(mktemp -d)

restore() {
  for image in "${images[@]}"; do
    if [[ -f "$saved/$image" ]]; then
      cp -p "$saved/$image" "$dir/$image"
    fi
  done
  rm -rf "$saved"
}
trap restore EXIT

for image in "${images[@]}"; do
  [[ -f "$dir/$image" ]] || { echo "FAIL ext2-reproducible: $dir/$image is not built" >&2; exit 1; }
  cp -p "$dir/$image" "$saved/$image"
done

rebuild() {
  rm -f "$dir/ext2.img" "$dir/ext2-shell.img"
  "$make_cmd" --no-print-directory "$@" "$dir/ext2.img" "$dir/ext2-shell.img" \
    >"$saved/make.log" 2>&1 || { cat "$saved/make.log" >&2; exit 1; }
}

rebuild
for image in "${images[@]}"; do
  if ! cmp -s "$saved/$image" "$dir/$image"; then
    echo "FAIL ext2-reproducible: two builds of $image differ:" >&2
    cmp -l "$saved/$image" "$dir/$image" | head -20 >&2 || true
    echo "  Every time an ext2 tool writes must be pinned (see the" \
         "KERNEL_EXT2_FAKE_TIME comment in the Makefile)." >&2
    exit 1
  fi
done

rebuild "KERNEL_EXT2_FAKE_TIME=$((epoch + 1))"
for image in "${images[@]}"; do
  if cmp -s "$saved/$image" "$dir/$image"; then
    echo "FAIL ext2-reproducible control: $image built at another fake" \
         "time is identical, so the comparison does not see the time fields" >&2
    exit 1
  fi
done

echo "PASS ext2-reproducible: ${#images[@]} images rebuilt byte-identical; control epoch differs"
