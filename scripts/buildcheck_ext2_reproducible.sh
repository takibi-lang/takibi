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

# GitHub issue #903: the comparison above holds the ELFs inside the images
# fixed. Recompile the guest ELFs the images take from kernel/build (Takibi
# output; the downloaded BusyBox and load programs are not built here) and
# their objects, and fail on any byte difference. Make's own database names
# them, so a new fixture ELF joins without a list to keep. The control: at
# least $min_elfs ELFs were found, and every one of them and its objects was
# removed and written again by this rebuild, so a comparison of files make
# never rebuilt cannot pass. The originals go back with their timestamps.
min_elfs=30
database=$("$make_cmd" --no-print-directory -pnq "$dir/ext2.img" "$dir/ext2-shell.img" 2>/dev/null || true)
mapfile -t elfs < <(awk -v d="$dir" '
  $1 == d "/ext2.img:" || $1 == d "/ext2-shell.img:" {
    for (i = 2; i <= NF; i++) if ($i ~ /^kernel\/build\/.*\.elf$/) print $i }' \
  <<<"$database" | sort -u)
if (( ${#elfs[@]} < min_elfs )); then
  echo "FAIL ext2-reproducible control: only ${#elfs[@]} compiled ELF inputs" \
       "found in make's database (at least $min_elfs expected)" >&2
  exit 1
fi
mapfile -t objects < <(for elf in "${elfs[@]}"; do
  awk -v e="$elf:" '$1 == e {
    for (i = 2; i <= NF; i++) if ($i ~ /^kernel\/build\/.*\.o$/) print $i }' \
    <<<"$database"; done | sort -u)
built=("${elfs[@]}" "${objects[@]}")
mkdir -p "$saved/elf"
for file in "${built[@]}"; do
  [[ -f "$file" ]] || { echo "FAIL ext2-reproducible: $file is not built" >&2; exit 1; }
  mkdir -p "$saved/elf/$(dirname "$file")"
  cp -p "$file" "$saved/elf/$file"
done
restore_elfs() {
  for file in "${built[@]}"; do
    if [[ -f "$saved/elf/$file" ]]; then cp -p "$saved/elf/$file" "$file"; fi
  done
  restore
}
trap restore_elfs EXIT
touch "$saved/marker"
rm -f "${built[@]}"
rebuild
for file in "${built[@]}"; do
  if [[ ! "$file" -nt "$saved/marker" ]]; then
    echo "FAIL ext2-reproducible control: $file was not rebuilt" >&2
    exit 1
  fi
  if ! cmp -s "$saved/elf/$file" "$file"; then
    echo "FAIL ext2-reproducible: two compiles of $file differ:" >&2
    cmp -l "$saved/elf/$file" "$file" | head -20 >&2 || true
    exit 1
  fi
done

echo "PASS ext2-reproducible: ${#images[@]} images rebuilt byte-identical; control epoch differs;" \
     "${#elfs[@]} compiled ELF inputs and ${#objects[@]} objects recompiled byte-identical"
