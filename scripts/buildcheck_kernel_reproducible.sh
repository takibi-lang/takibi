#!/usr/bin/env bash
# The production kernel objects are byte-reproducible (GitHub issue #1398).
#
# scripts/space_delta.py compares main.o across two builds and reads every
# difference as a change of the source; that holds only if one source
# compiles to one object. This recompiles each named kernel object with the
# exact command make would run for it -- read from `make -n -W SOURCE OBJECT`,
# so the check cannot drift from the rule -- into a temporary path, and fails
# on any byte difference from the object make built.
#
# Control: the recipe must be found (exactly one compile line ending in
# `-o OBJECT`), and the temporary object must not exist before the compile
# and must after it, so a comparison of a file nobody rewrote cannot pass.
#
# Usage: buildcheck_kernel_reproducible.sh SOURCE=OBJECT...
# Run from the rule that holds the kernel build lock.
set -euo pipefail

trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

make_cmd=${MAKE:-make}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(( $# > 0 )) || { echo "usage: buildcheck_kernel_reproducible.sh SOURCE=OBJECT..." >&2; exit 2; }

checked=0
for pair in "$@"; do
  source=${pair%%=*}
  object=${pair#*=}
  [[ -f "$object" ]] || { echo "FAIL kernel-reproducible: $object is not built" >&2; exit 1; }
  recipe=$("$make_cmd" --no-print-directory -n -W "$source" "$object" 2>/dev/null \
    | grep -F -- " -o $object" | grep -v -F -- " -o $object." || true)
  if [[ $(grep -c . <<<"$recipe") -ne 1 ]]; then
    echo "FAIL kernel-reproducible control: found $(grep -c . <<<"$recipe")" \
         "compile lines for $object in make's recipe, not one" >&2
    exit 1
  fi
  again="$work/$checked.o"
  rewritten=${recipe//" --facts $object.facts "/" --facts $again.facts "}
  rewritten=${rewritten%" -o $object"}" -o $again"
  [[ "$rewritten" != "$recipe" && ! -e "$again" ]] || {
    echo "FAIL kernel-reproducible control: could not redirect $object's compile" >&2; exit 1; }
  bash -c "$rewritten" >"$work/$checked.log" 2>&1 || { cat "$work/$checked.log" >&2; exit 1; }
  [[ -s "$again" ]] || { echo "FAIL kernel-reproducible control: the second compile of $object wrote nothing" >&2; exit 1; }
  if ! cmp -s "$object" "$again"; then
    echo "FAIL kernel-reproducible: two compiles of $object from the same sources differ:" >&2
    cmp -l "$object" "$again" | head -20 >&2 || true
    exit 1
  fi
  checked=$((checked + 1))
done

echo "PASS kernel-reproducible: $checked kernel object(s) recompiled byte-identical with make's own command"
